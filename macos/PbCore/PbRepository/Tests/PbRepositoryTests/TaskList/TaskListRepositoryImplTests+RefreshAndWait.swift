import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

/// R2-3: `refreshAndWait()` — the completion barrier the install operation's validate stage uses.
extension TaskListRepositoryImplTests {

    @Test func givenNothingRunning_whenRefreshAndWaitIsCalled_thenItRunsTheLoopItselfAndReturnsItsOwnResult() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.success(ctlClient(listing: ["a"])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let result = await sut.refreshAndWait()

        // then
        guard case .success = result else {
            Issue.record("expected success")
            return
        }
        #expect(sut.tasks.map(\.taskID) == ["a"])
    }

    @Test func givenAFailingPass_whenRefreshAndWaitIsCalled_thenItReturnsTheFailure() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        given(toolEnvironment).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let result = await sut.refreshAndWait()

        // then
        guard case .failure(let error) = result, case .notFound = error else {
            Issue.record("expected .notFound")
            return
        }
    }

    @Test func givenAPassAlreadyInFlight_whenRefreshAndWaitRegisters_thenItResolvesWithAPassThatStartedAfterItsCall() async {
        // given — the in-flight pass is blocked on a gate so a `refreshAndWait()` call is guaranteed
        // to arrive while it's still running; the ctl stub's listing changes from pass to pass so the
        // result each caller gets is distinguishable.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let gate = AsyncGate()
        let passCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            let thisPass = passCount.value + 1
            passCount.mutate { $0 = thisPass }
            if thisPass == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"tasks":[{"task_id":"pass\#(thisPass)","status":"running","backend":"claude"}]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let firstCall = Task { await sut.refresh() }
        await waitUntil { passCount.value >= 1 }
        let waiterCall = Task { await sut.refreshAndWait() }
        await waitUntil(timeout: 5) { sut.coalescedCallCount >= 1 } // registered behind pass 1
        gate.open()
        await firstCall.value
        let waiterResult = await waiterCall.value

        // then — the waiter is owed a pass that started after its own call (pass 2), never pass 1
        // (already running when it registered).
        guard case .success = waiterResult else {
            Issue.record("expected success")
            return
        }
        #expect(sut.tasks.map(\.taskID) == ["pass2"])
    }

    @Test func givenTheWaiterStartedTheLoop_whenAPollArmsAnotherPass_thenItReturnsAfterItsOwnPass() async {
        // given — pass 1 (started by the waiter) is held until a poll has armed pass 2, and pass 2 is
        // held for the rest of the test; the barrier must not wait on pass 2.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let firstPassGate = AsyncGate()
        let secondPassGate = AsyncGate()
        let passCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            let thisPass = passCount.value + 1
            passCount.mutate { $0 = thisPass }
            if thisPass == 1 { firstPassGate.waitSync() }
            if thisPass == 2 { secondPassGate.waitSync() }
            return .success(stdout(#"{"v":2,"tasks":[{"task_id":"pass\#(thisPass)","status":"running","backend":"claude"}]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        let waiterResult = LockedBox<Result<Void, ToolError>?>(nil)

        // when
        let waiter = Task {
            let result = await sut.refreshAndWait()
            waiterResult.mutate { $0 = result }
        }
        await waitUntil { passCount.value >= 1 }
        await sut.refresh() // coalesced: arms pass 2 and returns
        firstPassGate.open()
        await waitUntil { waiterResult.value != nil }

        // then — resolved with pass 1 while pass 2 is still held (the loop goes on to start it).
        let result = waiterResult.value
        await waitUntil { passCount.value >= 2 }
        let passesSeen = passCount.value
        secondPassGate.open()
        await waiter.value
        guard case .success = result else {
            Issue.record("expected the barrier to resolve with pass 1's success, got \(String(describing: result))")
            return
        }
        #expect(passesSeen == 2)
    }

    @Test func givenManyWaiters_whenTheQualifyingPassCompletes_thenEveryWaiterResumesExactlyOnce() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let gate = AsyncGate()
        let callCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            callCount.mutate { $0 += 1 }
            if callCount.value == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"tasks":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when — one in-flight pass, and five waiters registering behind it.
        let firstCall = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        let waiters = (0 ..< 5).map { _ in Task { await sut.refreshAndWait() } }
        await waitUntil(timeout: 5) { sut.coalescedCallCount >= 5 }
        gate.open()
        await firstCall.value
        var successCount = 0
        for waiter in waiters {
            if case .success = await waiter.value { successCount += 1 }
        }

        // then — every one of the five waiters resumed (no hang, no double-resume crash) and each
        // got a real success.
        #expect(successCount == 5)
    }

    @Test func givenARefreshCallAndARefreshAndWaitCallCoalesce_whenTheQualifyingPassRuns_thenBothAreSatisfied() async {
        // given — a competing plain `refresh()` (fire-and-forget) arrives alongside a
        // `refreshAndWait()` while a pass is already in flight; both must be served by the same
        // mechanism without one starving the other.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let gate = AsyncGate()
        let callCount = LockedBox(0)
        let runner = StubProcessRunner { _ in
            callCount.mutate { $0 += 1 }
            if callCount.value == 1 { gate.waitSync() }
            return .success(stdout(#"{"v":2,"tasks":[]}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let firstCall = Task { await sut.refresh() }
        await waitUntil { callCount.value >= 1 }
        let plainRefresh = Task { await sut.refresh() }
        let waiter = Task { await sut.refreshAndWait() }
        await waitUntil(timeout: 5) { sut.coalescedCallCount >= 2 } // both queued behind the first pass
        gate.open()
        await firstCall.value
        await plainRefresh.value
        let waiterResult = await waiter.value

        // then
        guard case .success = waiterResult else {
            Issue.record("expected success")
            return
        }
        #expect(callCount.value == 2)
    }
}
