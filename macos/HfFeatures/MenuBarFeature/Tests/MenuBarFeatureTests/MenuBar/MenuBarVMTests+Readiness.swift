import Combine
import Foundation
import HfCommon
import HfTestUtilities
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

extension MenuBarVMTests {

    // MARK: - New session readiness

    @Test func givenRuntimeNotReadyAtInit_whenCreated_thenNewSessionIsDisabled() {
        // given / when
        let harness = makeSUT(runtimeReady: false)

        // then
        #expect(harness.sut.canStartNewSession == false)
    }

    @Test func givenRuntimeReadyAtInit_whenCreated_thenNewSessionIsEnabled() {
        // given / when
        let harness = makeSUT()

        // then
        #expect(harness.sut.canStartNewSession)
    }

    @Test func givenReadinessPublishes_whenItFlips_thenTheFlagFollows() async {
        // given
        let harness = makeSUT(runtimeReady: false)
        let sut = harness.sut
        sut.didAppear()

        // when
        harness.runtimeReadySubject.send(true)
        await waitUntil { sut.canStartNewSession }

        // then
        #expect(sut.canStartNewSession)

        // when
        harness.runtimeReadySubject.send(false)
        await waitUntil { !sut.canStartNewSession }

        // then
        #expect(sut.canStartNewSession == false)
    }

    @Test func givenReadinessLost_whenNewSessionIsTapped_thenNothingIsRouted() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.runtimeReadySubject.send(false)
        await waitUntil { !sut.canStartNewSession }

        // when
        sut.didTapNewSession()

        // then
        verify(harness.routing).select(.any).called(0)
    }

    @Test func givenRuntimeReady_whenNewSessionIsTapped_thenItRoutesOnce() {
        // given
        let harness = makeSUT()

        // when
        harness.sut.didTapNewSession()

        // then
        verify(harness.routing).select(.value(.newSession)).called(1)
    }

    // MARK: - Workflow readiness seeding

    @Test func givenRuntimeNotReady_whenTheLabelAppears_thenWorkflowsAreNotPolledUntilReady() async {
        // given
        let useCase = MockMenuBarUseCase()
        let routing = MockMenuBarRouting()
        let workflowUseCase = MockWorkflowMenuBarUseCase()
        let readySubject = PassthroughSubject<Bool, Never>()
        given(useCase).connectionLine.willReturn("connecting…")
        given(useCase).runningCount.willReturn(0)
        given(useCase).runtimeReady.willReturn(false)
        given(useCase).runtimeReadyPublisher().willReturn(readySubject.eraseToAnyPublisher())
        given(useCase).installState.willReturn(.idle)
        given(useCase).lastCheckMessage.willReturn(nil)
        given(useCase).installAnywayBlockedMessage.willReturn(nil)
        given(useCase).tasksPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).countsPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).installStatePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).lastCheckMessagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).installAnywayBlockedMessagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(workflowUseCase).runs().willReturn([])
        let workflow = WorkflowMenuBarStatusVM(useCase: workflowUseCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let sut = MenuBarVM(useCase: useCase, routing: routing, workflowStatus: workflow, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())

        // when
        sut.didAppear()

        for _ in 0 ..< 10 { await Task.yield() }

        // then — not ready: no poll.
        verify(workflowUseCase).runs().called(0)

        // when
        readySubject.send(true)
        await waitUntil { sut.canStartNewSession }
        await waitUntil { !workflow.countsLoading }

        // then
        verify(workflowUseCase).runs().called(1)
        workflow.didDisappear()
    }
}
