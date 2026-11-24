import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MenuBarFeature
import Mockable
import MonitorCore
import Testing

extension MenuBarVMTests {

    // MARK: - Runtime card

    @Test(arguments: [
        (RuntimeSetupState.checking, MenuBarRuntimeCard.preparing),
        (.installing, .preparing),
        (.updating(installedVersion: "0.0.13", requiredVersion: "0.0.14"), .preparing),
        (.installationRequired(installedVersion: nil, requiredVersion: "0.0.14"), .setupRequired),
        (.failed("Package verification failed."), .failed(message: "Package verification failed.")),
        (.updateFailed(message: "Update refused.", installedVersion: "0.0.13", requiredVersion: "0.0.14"), .failed(message: "Update refused."))
    ])
    func givenEachRuntimeSetupState_whenObserved_thenTheMatchingCardShows(state: RuntimeSetupState, card: MenuBarRuntimeCard) async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        #expect(sut.runtimeCard == nil)

        // when
        harness.runtimeStateSubject.send(state)

        // then
        await waitUntil { sut.runtimeCard == card }
        #expect(sut.runtimeCard == card)
    }

    @Test func givenTheRuntimeBecomesReady_whenObserved_thenTheCardClears() async {
        // given
        let harness = makeSUT(runtimeState: .installing)
        let sut = harness.sut
        sut.didAppear()
        #expect(sut.runtimeCard == .preparing)

        // when
        harness.runtimeStateSubject.send(.ready)

        // then
        await waitUntil { sut.runtimeCard == nil }
        #expect(sut.runtimeCard == nil)
    }

    @Test func givenRuntimeNotReadyAtInit_whenCreated_thenTheCardAndDisabledNewSessionAreSeeded() {
        // given / when
        let harness = makeSUT(runtimeState: .checking)

        // then
        #expect(harness.sut.runtimeCard == .preparing)
        #expect(harness.sut.canStartNewSession == false)
    }

    @Test func givenRuntimeReadyAtInit_whenCreated_thenNewSessionIsEnabledAndNoCardShows() {
        // given / when
        let harness = makeSUT()

        // then
        #expect(harness.sut.canStartNewSession)
        #expect(harness.sut.runtimeCard == nil)
    }

    // MARK: - New session availability

    @Test func givenWorkAvailabilityPublishes_whenItFlips_thenNewSessionFollows() async {
        // given
        let harness = makeSUT(workAvailable: false)
        let sut = harness.sut
        sut.didAppear()

        // when
        harness.workAvailableSubject.send(true)
        await waitUntil { sut.canStartNewSession }

        // then
        #expect(sut.canStartNewSession)

        // when
        harness.workAvailableSubject.send(false)
        await waitUntil { !sut.canStartNewSession }

        // then
        #expect(sut.canStartNewSession == false)
    }

    @Test func givenWorkBecomesAvailable_whenObserved_thenNewSessionEnables() async {
        // given
        let harness = makeSUT(runtimeState: .installing)
        let sut = harness.sut
        sut.didAppear()
        #expect(sut.canStartNewSession == false)

        // when
        harness.runtimeStateSubject.send(.ready)
        harness.workAvailableSubject.send(true)

        // then
        await waitUntil { sut.canStartNewSession }
        #expect(sut.canStartNewSession)
    }

    @Test func givenReadinessLost_whenNewSessionIsTapped_thenNothingIsRouted() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.workAvailableSubject.send(false)
        await waitUntil { !sut.canStartNewSession }

        // when
        sut.didTapNewSession()

        // then
        verify(harness.routing).select(.any).called(0)
    }

    @Test func givenWorkAvailable_whenNewSessionIsTapped_thenItRoutesOnce() {
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
        let stateSubject = PassthroughSubject<RuntimeSetupState, Never>()
        given(useCase).connectionLine.willReturn("connecting…")
        given(useCase).runningCount.willReturn(0)
        given(useCase).runtimeSetupState.willReturn(.checking)
        given(useCase).runtimeSetupStatePublisher().willReturn(stateSubject.eraseToAnyPublisher())
        given(useCase).workAvailable.willReturn(false)
        given(useCase).workAvailablePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).refreshWork().willReturn()
        given(useCase).tasksPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).countsPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).listErrorPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).hasListedPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).titlesPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(workflowUseCase).runs().willReturn([])
        let workflow = WorkflowMenuBarStatusVM(useCase: workflowUseCase, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let sut = MenuBarVM(useCase: useCase, routing: routing, workflowStatus: workflow, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())

        // when
        sut.didAppear()

        for _ in 0 ..< 10 { await Task.yield() }

        // then — not ready: no poll.
        verify(workflowUseCase).runs().called(0)

        // when
        stateSubject.send(.ready)
        await waitUntil { sut.runtimeCard == nil }
        await waitUntil { !workflow.countsLoading }

        // then
        verify(workflowUseCase).runs().called(1)
        workflow.didDisappear()
    }
}
