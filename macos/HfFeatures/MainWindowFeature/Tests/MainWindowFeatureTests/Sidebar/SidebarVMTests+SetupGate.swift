//
//  SidebarVMTests+SetupGate.swift
//  MainWindowFeatureTests
//
//  The contract and capability gates replace the sidebar body with the setup line. Same harness and suite as
//  SidebarVMTests.
//

import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
extension SidebarVMTests {

    // MARK: - Setup gate

    func givenContractError() -> ToolError { .unsupportedVersion(tool: "harflow-ctl", version: "2") }

    @Test func givenAContractRefusal_whenListed_thenTheSetupGateShowsAndNoListErrorLinePrints() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()
        #expect(!sut.showsSetupGate)
        // when
        harness.listErrorSubject.send(givenContractError())
        await waitUntil { sut.showsSetupGate }
        // then
        #expect(sut.listErrorMessage == nil)
        #expect(sut.runtimeSetupState.isReady)
    }

    @Test func givenAContractGate_whenTheErrorClears_thenTheSetupGateHides() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.listErrorSubject.send(givenContractError())
        await waitUntil { sut.showsSetupGate }
        // when
        harness.listErrorSubject.send(nil)
        await waitUntil { !sut.showsSetupGate }
        // then
        #expect(!sut.showsSetupGate)
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenACapabilityRefusal_whenListed_thenTheSetupGateShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        // when
        harness.listErrorSubject.send(WireEnvelope.incompatibility(WireEnvelope.Detail.missingContract("events.v1")))
        await waitUntil { sut.showsSetupGate }
        // then
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenAnotherListingFailure_whenListed_thenNoSetupGateShowsAndTheLineKeepsItsMessage() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        let error = ToolError.timedOut(tool: "harflow-ctl task-list-page", seconds: 30)
        // when
        harness.listErrorSubject.send(error)
        await waitUntil { sut.listErrorMessage != nil }
        // then
        #expect(!sut.showsSetupGate)
        #expect(sut.listErrorMessage == error.message)
    }

    @Test func givenASetupGate_whenNewSessionAndNewWorkflowAreTapped_thenRoutingIsNotCalled() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.listErrorSubject.send(givenContractError())
        await waitUntil { sut.showsSetupGate }
        // when
        sut.didTapNewSession()
        sut.didTapNewWorkflow()
        // then
        verify(harness.routing).openNewSession().called(0)
        verify(harness.routing)
.select(.matching { destination in
            if case .newWorkflow = destination { return true }
            return false
        })
.called(0)
    }

    @Test func givenNoGate_whenNewSessionIsTapped_thenRoutingOpensIt() async {
        // given
        let harness = makeSUT()
        harness.sut.didAppear()
        // when
        harness.sut.didTapNewSession()
        // then
        verify(harness.routing).openNewSession().called(1)
    }

    @Test func givenAStandingContractError_whenTheSidebarIsCreated_thenTheSetupGateShowsBeforeAnyEmission() {
        // given
        let useCase = MockSidebarUseCase()
        let routing = MockSidebarRouting()
        given(useCase).connectionLine.willReturn("connecting…")
        given(useCase).backendCatalog.willReturn(.empty)
        given(useCase).listError.willReturn(givenContractError())
        stubAppearance(useCase)
        given(routing).selection.willReturn(nil)
        // when
        let sut = SidebarVM(useCase: useCase, routing: routing, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        // then
        #expect(sut.showsSetupGate)
    }
}
