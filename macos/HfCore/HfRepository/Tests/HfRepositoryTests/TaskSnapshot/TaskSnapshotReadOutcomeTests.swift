import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite struct TaskSnapshotReadOutcomeTests {
    @Test func givenEquivalentSuccessAndLocatorFailure_whenReading_thenEachAttemptHasFreshOutcomeAndCacheStaysRetained() async {
        // given
        let environment = MockToolEnvironmentRepository()
        let payload = #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","task":{"task_id":"t1","status":"running"}}"#
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(StubProcessRunner(output: stdout(payload))))
        let available = LockedBox(true)
        given(environment).ctl().willProduce { available.value ? .success(client) : .failure(.notFound(tool: "harflow-ctl", searched: [])) }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        let revisions = LockedBox<[UInt64]>([])
        let subscription = sut.readChangesPublisher().sink { _ in revisions.mutate { $0.append(sut.readRevision) } }
        // when
        await sut.refresh("t1")
        await sut.refresh("t1")
        #expect(sut.readOutcomes["t1"]?.revision == 2)
        #expect(sut.readOutcomes["t1"]?.task != nil)
        available.mutate { $0 = false }
        await sut.refresh("t1")
        // then
        #expect(sut.readOutcomes["t1"]?.revision == 3)
        #expect(sut.readOutcomes["t1"]?.task == nil)
        #expect(sut.snapshot("t1") != nil)
        #expect(revisions.value == [0, 1, 2, 3])
        withExtendedLifetime(subscription) {}
    }

    @Test func givenLocatorFailureBatchAndEviction_whenObserved_thenGlobalClockAndAuthoritativeEvictionIncludeUnreadIDs() async {
        // given
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.failure(.notFound(tool: "harflow-ctl", searched: [])))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        let evicted = LockedBox<UInt64?>(nil)
        let subscription = sut.readChangesPublisher().sink { change in
            if case .evicted(let revision, let keeping) = change {
                #expect(keeping == ["unread"])
                #expect(sut.readOutcomes.isEmpty)
                evicted.mutate { $0 = revision }
            }
        }
        // when
        await sut.refresh(ids: ["t1", "t2", "t1"])
        #expect(sut.readOutcomes.count == 2)
        sut.evict(keeping: ["unread"])
        // then
        #expect(sut.readRevision == 3)
        #expect(evicted.value == 3)
        withExtendedLifetime(subscription) {}
    }

    @Test(arguments: [false, true])
    func givenReadInFlight_whenEvicted_thenLateCompletionCannotRestoreEvictedOrReplaceNewAttempt(_ refreshAgain: Bool) async {
        // given
        let environment = MockToolEnvironmentRepository()
        let gate = AsyncGate()
        let entered = LockedBox(false)
        let calls = LockedBox(0)
        let runner = StubProcessRunner { _ in
            calls.mutate { $0 += 1 }
            let first = calls.value == 1
            if first {
                entered.mutate { $0 = true }
                gate.waitSync()
            }
            let status = first ? "running" : "completed"
            let payload = #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","task":{"task_id":"t1","status":"\#(status)"}}"#
            return .success(stdout(payload))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: PositiveCtlRunner(runner))))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: environment)
        let old = Task { await sut.refresh("t1") }
        await waitUntil { entered.value }
        #expect(entered.value)
        // when
        sut.evict(keeping: [])
        #expect(sut.readRevision == 2)
        if refreshAgain { await sut.refresh("t1") }
        gate.open()
        await old.value
        // then
        #expect(sut.readRevision == (refreshAgain ? 3 : 2))
        if refreshAgain {
            #expect(sut.readOutcomes["t1"]?.revision == 3)
            #expect(sut.readOutcomes["t1"]?.task?.status == .completed)
            #expect(sut.snapshot("t1")?.status == .completed)
        } else {
            #expect(sut.readOutcomes.isEmpty)
            #expect(sut.snapshots.isEmpty)
        }
    }

}
