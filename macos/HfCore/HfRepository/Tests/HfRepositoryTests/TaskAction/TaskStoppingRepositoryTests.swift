import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct TaskStoppingRepositoryTests {
    /// Independent getter hooks model production's clock-only getter without Mockable's
    /// cross-member producer serialization obscuring the action-lock overlap.
    private final class ControlledSnapshots: TaskSnapshotRepository, @unchecked Sendable {
        let readValues = LockedBox<[String: TaskSnapshotReadOutcome]>([:])
        let clock = LockedBox<UInt64>(10)
        let clockHook = LockedBox<(@Sendable () -> UInt64)?>(nil)
        let outcomeHook = LockedBox<(@Sendable () -> Void)?>(nil)
        let outcomeReads = LockedBox(0)
        let changes = PassthroughSubject<TaskSnapshotReadChange, Never>()
        var readRevision: UInt64 { clockHook.value?() ?? clock.value }
        var readOutcomes: [String: TaskSnapshotReadOutcome] {
            outcomeReads.mutate { $0 += 1 }
            let snapshot = readValues.value
            outcomeHook.value?()
            return snapshot
        }

        func readChangesPublisher() -> AnyPublisher<TaskSnapshotReadChange, Never> { changes.eraseToAnyPublisher() }
        var snapshots: [String: TaskInfo] { [:] }
        func snapshotsPublisher() -> AnyPublisher<[String: TaskInfo], Never> { Just([:]).eraseToAnyPublisher() }
        func snapshot(_: String) -> TaskInfo? { nil }
        func refresh(_: String) async {}
        func refresh(ids _: [String]) async {}
        func evict(keeping _: Set<String>) {}
    }

    private final class Fixture: @unchecked Sendable {
        let environment = MockToolEnvironmentRepository()
        let list = MockTaskListRepository()
        let snapshots = ControlledSnapshots()
        var reads: LockedBox<[String: TaskSnapshotReadOutcome]> { snapshots.readValues }
        var revision: LockedBox<UInt64> { snapshots.clock }
        var clockHook: LockedBox<(@Sendable () -> UInt64)?> { snapshots.clockHook }
        var outcomeHook: LockedBox<(@Sendable () -> Void)?> { snapshots.outcomeHook }
        var outcomeReads: LockedBox<Int> { snapshots.outcomeReads }
        var changes: PassthroughSubject<TaskSnapshotReadChange, Never> { snapshots.changes }
        let listings = PassthroughSubject<[TaskInfo], Never>()
        let sut: TaskActionRepositoryImpl

        init(result: String = #"{"task_id":"t1","status":"cancelled"}"#) {
            let payload = #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","result":\#(result)}"#
            given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:],
                runner: PositiveCtlRunner(StubProcessRunner(output: stdout(payload))))))
            given(list).tasks.willReturn([Self.task()])
            given(list).tasksPublisher().willReturn(listings.eraseToAnyPublisher())
            given(list).refresh().willReturn()
            self.sut = TaskActionRepositoryImpl(toolEnvironment: environment, taskListRepository: list, snapshotRepository: snapshots)
        }

        static func task(status: String = "running", owner: String = "alive", takenOver: Bool = false) -> TaskInfo {
            TaskInfo(.object(["task_id": .string("t1"), "status": .string(status), "taken_over": .bool(takenOver),
                           "supervision": .object(["owner_state": .string(owner)])]))!
        }

        func publish(_ revision: UInt64, task: TaskInfo?) {
            reads.mutate { $0["t1"] = TaskSnapshotReadOutcome(revision: revision, task: task) }
            changes.send(.updated)
        }
    }

    @Test func givenAcknowledgement_whenFreshAliveReadArrives_thenStoppingSurvivesEquivalentReadsAndOwnerRecovery() async throws {
        // given
        let fixture = Fixture()
        _ = try await fixture.sut.cancel("t1")
        #expect(!fixture.sut.isStopping("t1"))
        // when
        fixture.publish(11, task: Fixture.task())
        #expect(fixture.sut.isStopping("t1"))
        fixture.publish(12, task: Fixture.task())
        #expect(fixture.sut.isStopping("t1"))
        fixture.publish(13, task: Fixture.task(owner: "dead"))
        #expect(!fixture.sut.isStopping("t1"))
        fixture.publish(14, task: Fixture.task())
        // then
        #expect(fixture.sut.isStopping("t1"))
    }

    @Test func givenPreAcknowledgementAndOlderReads_whenDeliveredLater_thenTheyCannotQualifyOrClearNewerState() async throws {
        // given
        let fixture = Fixture()
        _ = try await fixture.sut.cancel("t1")
        // when
        fixture.publish(10, task: Fixture.task())
        #expect(!fixture.sut.isStopping("t1"))
        fixture.publish(12, task: Fixture.task())
        fixture.publish(11, task: nil)
        // then
        #expect(fixture.sut.isStopping("t1"))
    }

    @Test(arguments: ["unavailable", "terminal", "takeover", "unknown"])
    func givenQualifiedStop_whenAuthoritativeReadEndsIt_thenLaterRunningDoesNotRestoreIt(_ reason: String) async throws {
        // given
        let fixture = Fixture()
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(11, task: Fixture.task())
        // when
        let status = reason == "terminal" ? "completed" : reason == "unknown" ? "future" : "running"
        let task = reason == "unavailable" ? nil : Fixture.task(status: status, takenOver: reason == "takeover")
        fixture.publish(12, task: task)
        fixture.publish(13, task: Fixture.task())
        // then
        #expect(!fixture.sut.isStopping("t1"))
    }

    @Test func givenNewAcknowledgement_whenOlderEvictionArrives_thenOnlyNewerEvictionClearsIt() async throws {
        // given
        let fixture = Fixture()
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(11, task: Fixture.task())
        // when
        fixture.changes.send(.evicted(revision: 9, keeping: []))
        #expect(fixture.sut.isStopping("t1"))
        fixture.changes.send(.evicted(revision: 12, keeping: []))
        fixture.publish(13, task: Fixture.task())
        // then
        #expect(!fixture.sut.isStopping("t1"))
    }

    @Test func givenSuccessorBeforeAcknowledgement_whenCancelReturns_thenPredecessorCannotBecomeStopping() async throws {
        // given
        let fixture = Fixture()
        let successor = TaskInfo(.object(["task_id": .string("t2"), "status": .string("running"), "parent_task_id": .string("t1")]))!
        fixture.listings.send([Fixture.task(), successor])
        // when
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(11, task: Fixture.task())
        // then
        #expect(!fixture.sut.isStopping("t1"))
    }

    @Test(arguments: [#"{"status":"cancelled"}"#, #"{"task_id":"other","status":"cancelled"}"#,
                      #"{"task_id":"t1","status":"future"}"#,
                      #"{"task_id":"t1","status":"cancelled","cascade":{"not_signalled":["t1"]}}"#,
                      #"{"task_id":"t1","status":"cancelled","cascade":{"refused_tasks":[{"task_id":"t1"}]}}"#])
    func givenUnqualifiedAcknowledgement_whenFreshReadArrives_thenNoStopIsRecorded(_ result: String) async throws {
        // given
        let fixture = Fixture(result: result)
        // when
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(11, task: Fixture.task())
        // then
        #expect(!fixture.sut.isStopping("t1"))
    }

    @Test func givenEquivalentReads_whenStoppingEligibilityDoesNotChange_thenInvalidationsStayQuiet() async throws {
        // given
        let fixture = Fixture()
        let count = LockedBox(0)
        let subscription = fixture.sut.stoppingChangesPublisher().sink { count.mutate { $0 += 1 } }
        // when
        fixture.publish(9, task: Fixture.task())
        #expect(fixture.outcomeReads.value == 0)
        _ = try await fixture.sut.cancel("t1")
        #expect(count.value == 1)
        fixture.publish(11, task: Fixture.task())
        fixture.publish(12, task: Fixture.task())
        // then
        #expect(count.value == 2)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [false, true])
    func givenAcknowledgementHoldingActionLock_whenNewReadOrEvictionOverlapsInsertion_thenCallbackReconcilesAfterInsertion(_ eviction: Bool) async throws {
        // given — the clock getter models preemption after sampling the clock. It holds no
        // clock lock and sends no callbacks; only the caller's real action lock is held.
        let fixture = Fixture()
        let releaseClock = AsyncGate()
        let sampledClock = LockedBox(false)
        let callbackRead = LockedBox(false)
        let callbackStarted = LockedBox(false)
        let callbackFinished = LockedBox(false)
        fixture.clockHook.mutate { hook in
            hook = {
                let baseline = fixture.revision.value
                sampledClock.mutate { $0 = true }
                releaseClock.waitSync()
                return baseline
            }
        }
        let cancel = Task.detached { try await fixture.sut.cancel("t1") }
        await waitUntil { sampledClock.value }
        #expect(sampledClock.value)
        // when — the eviction reads its snapshot before locking; an update first checks the
        // request set under the same action lock. Both must wait until insertion completes.
        fixture.revision.mutate { $0 = 11 }
        fixture.reads.mutate { $0["t1"] = TaskSnapshotReadOutcome(revision: 11, task: Fixture.task()) }
        fixture.outcomeHook.mutate { hook in hook = { callbackRead.mutate { $0 = true } } }
        let callback = Task.detached {
            callbackStarted.mutate { $0 = true }
            fixture.changes.send(eviction ? .evicted(revision: 11, keeping: []) : .updated)
            callbackFinished.mutate { $0 = true }
        }
        await waitUntil { eviction ? callbackRead.value : callbackStarted.value }
        #expect(eviction ? callbackRead.value : callbackStarted.value)
        #expect(!callbackFinished.value)
        releaseClock.open()
        _ = try await cancel.value
        await callback.value
        // then — a fresh read qualifies the inserted acknowledgement; eviction removes it.
        #expect(fixture.sut.isStopping("t1") == !eviction)
        fixture.publish(12, task: Fixture.task())
        #expect(fixture.sut.isStopping("t1") == !eviction)
    }

    @Test func givenEvictionBeforeClockCapture_whenNewAcknowledgementIsInserted_thenFreshReadQualifiesNewRequest() async throws {
        // given — cancel has returned, and outcome sampling is preempted before the action lock.
        let fixture = Fixture()
        let once = LockedBox(false)
        fixture.outcomeHook.mutate { hook in
            hook = {
                guard !once.value else { return }
                once.mutate { $0 = true }
                fixture.revision.mutate { $0 = 11 }
                fixture.changes.send(.evicted(revision: 11, keeping: []))
            }
        }
        // when
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(12, task: Fixture.task())
        // then — the acknowledged request starts after eviction, so it is independent of it.
        #expect(once.value)
        #expect(fixture.sut.isStopping("t1"))
    }

    @Test func givenStoppingSubscriber_whenItReadsSynchronously_thenNoLockIsHeldDuringPublication() async throws {
        // given
        let fixture = Fixture()
        let observed = LockedBox(false)
        let subscription = fixture.sut.stoppingChangesPublisher().sink { observed.mutate { $0 = fixture.sut.isStopping("t1") } }
        // when
        _ = try await fixture.sut.cancel("t1")
        fixture.publish(11, task: Fixture.task())
        // then
        #expect(observed.value)
        withExtendedLifetime(subscription) {}
    }
}
