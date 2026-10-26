import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import HfUtilities
import Mockable
import MonitorCore
import Testing

// MARK: - RecoverySnapshotGate

/// Models the production Subjected setter lock, with a controllable read before that lock.
private final class RecoverySnapshotGate: @unchecked Sendable {
    @Subjected var values: [String: TaskInfo] = [:]
    let blockReads = LockedBox(false)
    let readEntered = LockedBox(false)
    let resumeRead = DispatchSemaphore(value: 0)

    func snapshot(_ id: String) -> TaskInfo? {
        if blockReads.value {
            readEntered.mutate { $0 = true }
            _ = resumeRead.wait(timeout: .now() + 5)
        }
        return values[id]
    }
}

extension RecoveryEventStreamRepositoryTests {
    private func lostSnapshot() -> TaskInfo {
        TaskInfo(.object([
            "task_id": .string("lost-task"), "status": .string("running"),
            "supervision": .object(["capture_state": .string("lost_with_owner")])
        ]))!
    }

    private func emptyBase() -> MockEventStreamRepository {
        let base = MockEventStreamRepository()
        given(base).acquire(.any).willProduce { NullEventStreamLease(taskID: $0) }
        given(base).events(for: .any).willReturn([])
        given(base).items(for: .any).willReturn([])
        given(base).eventsPublisher(for: .any).willReturn(Just([]).eraseToAnyPublisher())
        return base
    }

    private func pollingScheduler(_ poll: LockedBox<(@Sendable () -> Void)?>) -> MockScheduling {
        let scheduler = MockScheduling()
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willProduce { _, work in
            poll.mutate { $0 = work }
            return AnyCancellable { poll.mutate { $0 = nil } }
        }
        return scheduler
    }

    @Test
    func givenSnapshotReadBlocked_whenSnapshotPublishesAndLeaseReleases_thenBothCompleteWithoutJoiningRead() async {
        // given — park a timer refresh before reading Subjected. Publishing takes Subjected's
        // lock and synchronously invokes recovery's sink, reproducing the original lock order.
        let gate = RecoverySnapshotGate()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(gate.$values.eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willProduce { gate.snapshot($0) }
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let sut = RecoveryEventStreamRepository(base: emptyBase(), environment: MockToolEnvironmentRepository(),
                                                 snapshots: snapshots, scheduler: pollingScheduler(poll))
        let lease = sut.acquire("lost-task")
        await waitUntil { poll.value != nil }
        gate.blockReads.mutate { $0 = true }
        poll.value?()
        await waitUntil { gate.readEntered.value }
        #expect(gate.readEntered.value)
        let publicationFinished = LockedBox(false)
        let releaseFinished = LockedBox(false)

        // when — neither setter callback nor UI release may wait for the session's blocked work.
        DispatchQueue.global().async {
            gate.values = [:]
            publicationFinished.mutate { $0 = true }
        }
        DispatchQueue.global().async {
            lease.release()
            releaseFinished.mutate { $0 = true }
        }
        await waitUntil(timeout: 1) { publicationFinished.value && releaseFinished.value }

        // then
        #expect(publicationFinished.value)
        #expect(releaseFinished.value)
        gate.blockReads.mutate { $0 = false }
        gate.resumeRead.signal()
        await waitUntil { poll.value == nil }
        #expect(poll.value == nil)
        #expect(sut.events(for: "lost-task").isEmpty)
    }

    @Test
    func givenRealSnapshots_whenRefreshPollAndReleaseRace_thenAllFinishAndNewLeaseStillRecovers() async {
        // given — use the actual mutationLock + Subjected producer rather than a mock publisher.
        let environment = MockToolEnvironmentRepository()
        let status = LockedBox(0)
        let runner = compatibleRunner { call in
            if call.arguments.first == "recovery-activity" { return .success(stdout(recoveryPage())) }
            status.mutate { $0 += 1 }
            let value = status.value
            let task = lostSnapshot().raw
            var document = task
            document["title"] = .string("refresh-\(value)")
            return .success(stdout(JSONValue.object([
                "product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                "product_version": .string("0.0.1"), "tasks": .array([.object(document)]), "errors": .object([:])
            ])
.rendered()))
        }
        given(environment).ctl().willReturn(.success(CtlClient(
            executable: "/fake/ctl", environment: ["HOME": NSHomeDirectory()], runner: runner
        )))
        let snapshots = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        await snapshots.refresh(ids: ["lost-task"])
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let sut = RecoveryEventStreamRepository(base: emptyBase(), environment: environment,
                                                 snapshots: snapshots, scheduler: pollingScheduler(poll))
        let lease = sut.acquire("lost-task")
        await waitUntil { poll.value != nil }
        let finished = LockedBox(0)

        // when
        for _ in 0 ..< 100 {
            Task.detached {
                await snapshots.refresh(ids: ["lost-task"])
                poll.value?()
                finished.mutate { $0 += 1 }
            }
        }
        DispatchQueue.global().async {
            for _ in 0 ..< 1000 { poll.value?() }
            finished.mutate { $0 += 1 }
        }
        DispatchQueue.global().async { lease.release(); finished.mutate { $0 += 1 } }
        await waitUntil(timeout: 5) { finished.value == 102 && poll.value == nil }

        // then — bounded completion, no retained released state, and a usable replacement session.
        #expect(finished.value == 102)
        #expect(poll.value == nil)
        #expect(sut.events(for: "lost-task").isEmpty)
        let replacement = sut.acquire("lost-task")
        await waitUntil(timeout: 5) { !sut.events(for: "lost-task").isEmpty }
        #expect(!sut.events(for: "lost-task").isEmpty)
        replacement.release()
        await waitUntil { poll.value == nil }
    }

    @Test
    func givenDelayedOldRuntime_whenSelectionChanges_thenOnlyReplacementRuntimePublishes() async {
        // given
        let entered = LockedBox(false)
        let completed = LockedBox(false)
        let resume = DispatchSemaphore(value: 0)
        let oldRunner = compatibleRunner { call in
            if call.arguments.first == "recovery-activity" {
                entered.mutate { $0 = true }
                _ = resume.wait(timeout: .now() + 5)
                completed.mutate { $0 = true }
                return .success(stdout(recoveryPage().replacingOccurrences(of: "recovered text", with: "obsolete text")))
            }
            return .success(stdout("{}"))
        }
        let newRunner = compatibleRunner { _ in .success(stdout(recoveryPage())) }
        let selected = LockedBox(CtlClient(executable: "/old/ctl", environment: ["HOME": NSHomeDirectory()], runner: oldRunner))
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willProduce { .success(selected.value) }
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(Just([:]).eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willReturn(lostSnapshot())
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let sut = RecoveryEventStreamRepository(base: emptyBase(), environment: environment,
                                                 snapshots: snapshots, scheduler: pollingScheduler(poll))
        let lease = sut.acquire("lost-task")
        await waitUntil { entered.value }
        #expect(entered.value)

        // when — advance runtime while its predecessor's process ignores cancellation.
        selected.mutate { $0 = CtlClient(executable: "/new/ctl", environment: ["HOME": NSHomeDirectory()], runner: newRunner) }
        poll.value?()
        await waitUntil { sut.events(for: "lost-task").contains { $0.rawLine.contains("recovered text") } }
        resume.signal()
        await waitUntil { completed.value }
        poll.value?()

        // then
        #expect(sut.events(for: "lost-task").contains { $0.rawLine.contains("recovered text") })
        #expect(!sut.events(for: "lost-task").contains { $0.rawLine.contains("obsolete text") })
        lease.release()
        await waitUntil { poll.value == nil }
    }

    @Test
    func givenDelayedRecovery_whenCaptureRestoresAndFinalLeaseReleases_thenObsoleteResultStaysHidden() async {
        // given
        let entered = LockedBox(false)
        let completed = LockedBox(false)
        let resume = DispatchSemaphore(value: 0)
        let runner = compatibleRunner { call in
            if call.arguments.first == "recovery-activity" {
                entered.mutate { $0 = true }
                _ = resume.wait(timeout: .now() + 5)
                completed.mutate { $0 = true }
                return .success(stdout(recoveryPage()))
            }
            return .success(stdout("{}"))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(
            executable: "/fake/ctl", environment: ["HOME": NSHomeDirectory()], runner: runner
        )))
        let gate = RecoverySnapshotGate()
        gate.values = ["lost-task": lostSnapshot()]
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(gate.$values.eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willProduce { gate.snapshot($0) }
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let sut = RecoveryEventStreamRepository(base: emptyBase(), environment: environment,
                                                 snapshots: snapshots, scheduler: pollingScheduler(poll))
        let lease = sut.acquire("lost-task")
        await waitUntil { entered.value }
        #expect(entered.value)
        let delivered = LockedBox<[TaskEvent]>([])
        let subscription = sut.eventsPublisher(for: "lost-task").sink { value in delivered.mutate { $0 = value } }

        // when — restoring capture and releasing do not wait for the old process.
        gate.values = [:]
        lease.release()
        await waitUntil { poll.value == nil }
        #expect(poll.value == nil)
        resume.signal()
        await waitUntil { completed.value }

        // then
        #expect(sut.events(for: "lost-task").isEmpty)
        #expect(delivered.value.isEmpty)
        subscription.cancel()
    }

    @Test
    func givenDelayedPoll_whenHealthyThenLostArriveBeforeRefreshReads_thenReplacementPollStarts() async {
        // given — hold the old command open, then park the session's next snapshot read.
        let calls = LockedBox(0)
        let resumeOld = DispatchSemaphore(value: 0)
        let runner = compatibleRunner { call in
            guard call.arguments.first == "recovery-activity" else { return .success(stdout("{}")) }
            calls.mutate { $0 += 1 }
            let number = calls.value
            if number == 1 {
                _ = resumeOld.wait(timeout: .now() + 5)
                return .success(stdout(recoveryPage().replacingOccurrences(of: "recovered text", with: "obsolete text")))
            }
            return .success(stdout(recoveryPage()))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(
            executable: "/fake/ctl", environment: ["HOME": NSHomeDirectory()], runner: runner
        )))
        let gate = RecoverySnapshotGate()
        let lost = lostSnapshot()
        gate.values = ["lost-task": lost]
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(gate.$values.eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willProduce { gate.snapshot($0) }
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let sut = RecoveryEventStreamRepository(base: emptyBase(), environment: environment,
                                                 snapshots: snapshots, scheduler: pollingScheduler(poll))
        let lease = sut.acquire("lost-task")
        defer { resumeOld.signal(); lease.release() }
        await waitUntil { calls.value == 1 }
        #expect(calls.value == 1)
        gate.blockReads.mutate { $0 = true }
        poll.value?()
        await waitUntil { gate.readEntered.value }
        #expect(gate.readEntered.value)

        // when — the queue observes only the latest lost snapshot, but the healthy notification
        // has already invalidated the old operation's generation.
        gate.values = [:]
        gate.values = ["lost-task": lost]
        gate.blockReads.mutate { $0 = false }
        gate.resumeRead.signal()
        await waitUntil(timeout: 2) {
            calls.value >= 2 && sut.events(for: "lost-task").contains { $0.rawLine.contains("recovered text") }
        }

        // then — recovery restarts while the invalidated process is still blocked.
        #expect(calls.value >= 2)
        #expect(sut.events(for: "lost-task").contains { $0.rawLine.contains("recovered text") })
        #expect(!sut.events(for: "lost-task").contains { $0.rawLine.contains("obsolete text") })
    }

}
