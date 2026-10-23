import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite
struct RecoveryEventStreamRepositoryTests {
    private func scheduler() -> MockScheduling {
        let value = MockScheduling()
        given(value).scheduleRepeating(every: .any, execute: .any).willReturn(AnyCancellable {})
        return value
    }

    @Test
    func givenTaskWithoutLostCapture_whenAcquired_thenRecoveryDoesNotPublishSyntheticEvents() async {
        let base = MockEventStreamRepository()
        given(base).acquire(.any).willReturn(NullEventStreamLease(taskID: "task"))
        given(base).events(for: .any).willReturn([])
        given(base).items(for: .any).willReturn([])
        let environment = MockToolEnvironmentRepository()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(Just([:]).eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willReturn(nil)
        let sut = RecoveryEventStreamRepository(base: base, environment: environment, snapshots: snapshots, scheduler: scheduler())
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { sut.events(for: "task").isEmpty }
        #expect(sut.events(for: "task").isEmpty)
        #expect(sut.items(for: "task").isEmpty)
    }

    @Test
    func givenRepeatedAcquireAndRelease_whenFinalLeaseReleases_thenRepositoryStopsOwningTask() {
        let base = MockEventStreamRepository()
        given(base).acquire(.any).willReturn(NullEventStreamLease(taskID: "task"))
        given(base).events(for: .any).willReturn([])
        given(base).items(for: .any).willReturn([])
        let environment = MockToolEnvironmentRepository()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(Just([:]).eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willReturn(nil)
        let sut = RecoveryEventStreamRepository(base: base, environment: environment, snapshots: snapshots, scheduler: scheduler())
        let first = sut.acquire("task")
        let second = sut.acquire("task")
        first.release()
        second.release()
        #expect(sut.events(for: "task").isEmpty)
    }

    private struct PositiveRig {
        let sut: RecoveryEventStreamRepository
        let poll: LockedBox<(@Sendable () -> Void)?>
        let recoveryCalls: LockedBox<Int>
        let baseEvent: TaskEvent
    }

    private func recoveryPage() -> String {
        #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","task_id":"lost-task","#
            + #"recovery_activity":{"source":"backend_transcript","display_only":true,"events":["#
            + #"{"source_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","#
            + #"kind":"assistant_text","source_ts":"2026-10-23T00:00:00Z","text":"recovered text"},"#
            + #"{"source_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","#
            + #"kind":"tool_call","call_id":"read-1","tool":"Read","input_preview":"{}"},"#
            + #"{"source_id":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","#
            + #"kind":"tool_result","call_id":"read-1","ok":true,"output_tail":"done"}],"#
            + #""next_cursor":"same","reset":false,"has_more":false,"notices":[]}}}"#
    }

    private func positiveRig(taskID: String) -> PositiveRig {
        let baseEvent = TaskEvent(line: currentEventFixture(
            #"{"v":1,"seq":7,"kind":"task_finished","status":"completed","summary":"captured summary"}"#
        ))!
        let base = MockEventStreamRepository()
        given(base).acquire(.any).willReturn(NullEventStreamLease(taskID: taskID))
        given(base).events(for: .any).willReturn([baseEvent])
        given(base).items(for: .any).willReturn([])
        given(base).summary(for: .any).willReturn(EventSummary())
        given(base).activity(for: .any).willReturn(ActivityCounts())
        given(base).prompt(for: .any).willReturn("captured prompt")
        let home = NSHomeDirectory()
        let snapshot = TaskInfo(.object([
            "task_id": .string(taskID), "status": .string("completed"),
            "supervision": .object([
                "owner_state": .string("dead"), "process_state": .string("alive"),
                "capture_state": .string("lost_with_owner"), "live_input_state": .string("closed_with_owner")
            ])
        ]))!
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshotsPublisher().willReturn(Just([taskID: snapshot]).eraseToAnyPublisher())
        given(snapshots).snapshot(.any).willReturn(snapshot)
        let poll = LockedBox<(@Sendable () -> Void)?>(nil)
        let scheduler = MockScheduling()
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willProduce { _, work in
            poll.mutate { $0 = work }
            return AnyCancellable { poll.mutate { $0 = nil } }
        }
        let recoveryCalls = LockedBox(0)
        let runner = compatibleRunner { call in
            if call.arguments.first == "recovery-activity" {
                recoveryCalls.mutate { $0 += 1 }
                return .success(stdout(recoveryPage()))
            }
            return .success(stdout("{}"))
        }
        let environment = MockToolEnvironmentRepository()
        given(environment).home.willReturn(home)
        given(environment).tasksDirectory.willReturn(home + "/.harflow/tasks")
        given(environment).ctl().willReturn(.success(CtlClient(
            executable: "/fake/ctl", environment: ["HOME": home], runner: runner
        )))
        let sut = RecoveryEventStreamRepository(base: base, environment: environment,
                                                 snapshots: snapshots, scheduler: scheduler)
        return PositiveRig(sut: sut, poll: poll, recoveryCalls: recoveryCalls, baseEvent: baseEvent)
    }

    @Test
    func givenLostCapture_whenRecoveryPollReturnsPages_thenSyntheticActivityIsVisibleOnceAndLeaseStopsPolling() async {
        // given
        let taskID = "lost-task"
        let rig = positiveRig(taskID: taskID)
        let lease = rig.sut.acquire(taskID)

        // when
        await waitUntil(timeout: 5) {
            let events = rig.sut.events(for: taskID)
            return events.contains { if case .assistantText(let text, _, _) = $0.kind { return text == "recovered text" }; return false }
                && events.contains { if case .toolCall = $0.kind { return true }; return false }
                && events.contains { if case .toolResult = $0.kind { return true }; return false }
        }
        let recovered = rig.sut.events(for: taskID)
        let recoveredIDs = recovered.filter { $0.seq >= Int.max / 2 }.map(\.seq)
        rig.poll.value?()
        await waitUntil(timeout: 5) { rig.recoveryCalls.value >= 2 }

        // then
        #expect(rig.sut.events(for: taskID).count == recovered.count)
        #expect(recovered.contains(rig.baseEvent))
        #expect(recovered.contains { if case .notice(let text) = $0.kind { return text.contains("display only") }; return false })
        #expect(Set(recoveredIDs).count == recoveredIDs.count)
        #expect(rig.sut.summary(for: taskID) == EventSummary())
        #expect(rig.sut.prompt(for: taskID) == "captured prompt")
        lease.release()
        #expect(rig.poll.value == nil)
    }
}
