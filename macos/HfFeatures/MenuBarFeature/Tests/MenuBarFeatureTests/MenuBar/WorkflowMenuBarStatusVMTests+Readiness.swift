import Foundation
import HfCommon
import HfTestUtilities
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowMenuBarStatusVM runtime readiness

extension WorkflowMenuBarStatusVMTests {

    private final class ReadinessCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }

    private final class SlowRuns: WorkflowMenuBarUseCase, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<[[String: JSONValue]], Error>?
        private var started = 0
        var startedCount: Int { lock.withLock { started } }

        func runs() async throws -> [[String: JSONValue]] {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock { self.continuation = continuation; started += 1 }
            }
        }

        func finish(_ result: Result<[[String: JSONValue]], Error>) {
            let pending = lock.withLock { () -> CheckedContinuation<[[String: JSONValue]], Error>? in
                defer { continuation = nil }
                return continuation
            }
            pending?.resume(with: result)
        }
    }

    @Test func givenNotReady_whenAppearedAcrossVisibilityWakes_thenNothingIsPolled() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = ReadinessCalls()
        given(useCase).runs().willProduce { calls.increment(); return [] }
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: visibility, scheduler: CapturingScheduler())

        // when
        sut.didAppear()
        visibility.setMenuBarPopoverOpen(true)
        visibility.setMainWindowVisible(true)
        await sut.refresh()
        for _ in 0 ..< 10 { await Task.yield() }

        // then
        #expect(calls.value == 0)
        #expect(sut.countsLoading == false)
        #expect(sut.activeCount == 0)
        #expect(sut.attentionCount == 0)
        #expect(sut.errorText == nil)
        #expect(sut.rows.isEmpty)
        sut.didDisappear()
    }

    @Test func givenNotReady_whenAppearedTwiceThenReady_thenExactlyOnePollStarts() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = ReadinessCalls()
        given(useCase).runs().willProduce { calls.increment(); return [] }
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.didAppear()
        sut.didAppear()

        // when
        sut.setRuntimeReady(true)
        await waitUntil { calls.value == 1 }

        // then
        #expect(calls.value == 1)
        sut.didDisappear()
    }

    @Test func givenNotReady_whenDisappearedThenReady_thenNothingIsPolled() async {
        // given
        let useCase = SlowRuns()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.didAppear()
        sut.didDisappear()

        // when
        sut.setRuntimeReady(true)
        for _ in 0 ..< 10 { await Task.yield() }

        // then — ready but not appeared: no poll was started.
        #expect(useCase.startedCount == 0)
    }

    @Test func givenRefreshWhileNotReady_whenAwaited_thenTheUseCaseIsNotCalled() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willReturn([])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())

        // when
        await sut.refresh()

        // then
        verify(useCase).runs().called(0)
    }

    @Test func givenAppearedAndReadinessSeeded_whenAppearing_thenCountsLoadBeforeTheFirstResult() async {
        // given
        let useCase = SlowRuns()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.setRuntimeReady(true)

        // when
        sut.didAppear()

        // then
        #expect(sut.countsLoading)
        await waitUntil { useCase.startedCount == 1 }
        sut.didDisappear()
        useCase.finish(.success([]))
    }

    @Test func givenBecomesReadyWhileAppeared_whenReadyArrives_thenItPollsAtOnceWithCountsLoading() async {
        // given
        let useCase = SlowRuns()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.didAppear()
        #expect(useCase.startedCount == 0)

        // when
        sut.setRuntimeReady(true)
        await waitUntil { useCase.startedCount == 1 }

        // then
        #expect(sut.countsLoading)
        sut.didDisappear()
        useCase.finish(.success([]))
    }

    @Test func givenReadyAndPolling_whenAppearedAgainOrReadyRepeats_thenNoExtraPollAndCountsAreUntouched() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        let calls = ReadinessCalls()
        given(useCase).runs().willProduce { calls.increment(); return [self.run("a", status: "running")] }
        let scheduler = CapturingScheduler()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: scheduler)
        sut.setRuntimeReady(true)
        sut.didAppear()
        await waitUntil { calls.value == 1 && !sut.countsLoading }

        // when
        sut.didAppear()
        sut.setRuntimeReady(true)
        for _ in 0 ..< 10 { await Task.yield() }

        // then
        #expect(calls.value == 1)
        #expect(sut.countsLoading == false)
        #expect(sut.activeCount == 1)
        sut.didDisappear()
    }

    @Test func givenReadinessLostMidRefresh_whenTheResultArrives_thenItIsDiscardedAndEverythingIsCleared() async {
        // given — a direct refresh with no token and no cancellation, so only the readiness guard can discard it.
        let useCase = SlowRuns()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.setRuntimeReady(true)
        let refresh = Task { @MainActor in await sut.refresh() }
        await waitUntil { useCase.startedCount == 1 }

        // when
        sut.setRuntimeReady(false)
        useCase.finish(.success([run("late", status: "running")]))
        await refresh.value

        // then
        #expect(sut.rows.isEmpty)
        #expect(sut.countsLoading == false)
        #expect(sut.activeCount == 0)
        #expect(sut.attentionCount == 0)
        #expect(sut.errorText == nil)
    }

    @Test func givenReadinessLostMidRefresh_whenTheUseCaseThrows_thenNoErrorTextIsShown() async {
        // given
        let useCase = SlowRuns()
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.setRuntimeReady(true)
        let refresh = Task { @MainActor in await sut.refresh() }
        await waitUntil { useCase.startedCount == 1 }

        // when
        sut.setRuntimeReady(false)
        useCase.finish(.failure(ToolError.unsupportedCommand(tool: "harflow-ctl", command: "workflow-list-runs", detail: "older CLI")))
        await refresh.value

        // then
        #expect(sut.errorText == nil)
        #expect(sut.rows.isEmpty)
        #expect(sut.countsLoading == false)
    }

    @Test func givenRowsLoaded_whenReadinessIsLost_thenRowsAndCountsAreCleared() async {
        // given
        let useCase = MockWorkflowMenuBarUseCase()
        given(useCase).runs().willReturn([run("a", status: "running")])
        let sut = WorkflowMenuBarStatusVM(useCase: useCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        sut.setRuntimeReady(true)
        await sut.refresh()
        #expect(sut.rows.count == 1)

        // when
        sut.setRuntimeReady(false)

        // then
        #expect(sut.rows.isEmpty)
        #expect(sut.activeCount == 0)
        #expect(sut.countsLoading == false)
    }
}
