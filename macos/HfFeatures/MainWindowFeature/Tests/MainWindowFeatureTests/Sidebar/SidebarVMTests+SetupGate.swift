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

    // MARK: - Task store gate (the sidebar body stays; creation is blocked)

    func givenStoreRefusal() -> StoreRecoveryState {
        .incompatible(.structuredRefusal(
            code: "state_incompatible", message: "Unsupported state root: foreign store marker",
            data: ["reason": .string("foreign_store"), "state_root": .string("/tmp/harflow-state")]
        ))
    }

    @Test func givenAStoreRefusal_whenObserved_thenTheBodyStaysAndCreationIsBlocked() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        #expect(sut.creationIsAvailable)
        // when
        sut.applyStoreRecovery(givenStoreRefusal())
        // then
        #expect(!sut.showsSetupGate)
        #expect(sut.storeNeedsAttention)
        #expect(!sut.creationIsAvailable)
    }

    @Test(arguments: [MonitorDestination.newSession, .workflowLibrary, .workflow("draft")])
    func givenAStoreRefusal_whenACreationRowIsSelected_thenSelectionIsUnchangedAndNothingIsRouted(destination: MonitorDestination) {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.applyStoreRecovery(givenStoreRefusal())
        let before = sut.selection
        // when
        sut.didSelect(destination)
        sut.didTapNewSession()
        sut.didTapNewWorkflow()
        // then
        #expect(sut.selection == before)
        verify(harness.routing).select(.any).called(0)
        verify(harness.routing).openNewSession().called(0)
    }

    @Test func givenAStoreRefusal_whenANonCreationRowIsSelected_thenItStillRoutes() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.applyStoreRecovery(givenStoreRefusal())
        // when
        sut.didSelect(.statistics)
        // then
        #expect(sut.selection == .statistics)
        verify(harness.routing).select(.value(.statistics)).called(1)
    }

    @Test func givenAStoreRefusal_whenTheStoreClears_thenCreationIsRestored() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.applyStoreRecovery(givenStoreRefusal())
        // when
        sut.applyStoreRecovery(.idle)
        sut.didTapNewSession()
        sut.didSelect(.newSession)
        // then
        #expect(sut.creationIsAvailable)
        verify(harness.routing).openNewSession().called(1)
        verify(harness.routing).select(.value(.newSession)).called(1)
    }

    @Test func givenAnInspectionInFlight_whenObserved_thenCreationIsNotBlocked() {
        // given
        let sut = makeSUT().sut
        // when
        sut.applyStoreRecovery(.inspecting)
        // then
        #expect(sut.storeNeedsAttention)
        #expect(sut.creationIsAvailable)
    }

    @Test func givenCreationBlockedByTheStore_whenTheNavigationEntriesAreBuilt_thenOnlyCreationRowsAreDisabled() {
        // given / when
        let entries = SidebarNavigationEntry.unifiedEntries(badge: .none, creationAvailable: false)
        // then
        #expect(entries.filter { !$0.isEnabled }.map(\.destination) == [.newSession, .workflowLibrary])
        #expect(SidebarNavigationEntry.unifiedEntries(badge: .none).filter { !$0.isEnabled }.isEmpty)
        let disabled = SidebarListEntry(id: "navigation:new-task", content: .navigation(entries[0]))
        #expect(disabled.destination == nil)
    }
}
