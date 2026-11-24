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

    // MARK: - Refresh note

    @Test func givenAReadyRuntimeAndAnUnreadableListing_whenObserved_thenRefreshNoteWithoutCode() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        let failure = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "")

        // when
        harness.listErrorSubject.send(failure)

        // then
        await waitUntil { sut.refreshNote != nil }
        #expect(sut.refreshNote?.message == failure.displayMessage)
        #expect(sut.isConnected == false)
        #expect(sut.runtimeCard == nil)
    }

    @Test func givenARefusalWithACode_whenObserved_thenRefreshNoteShowsTheMessageAndNoCode() async {
        // given — the popover note matches the sidebar's: the sentence only, never the refusal code.
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        let failure = ToolError.refused(code: "denied", message: "harflow-ctl refused the request.")

        // when
        harness.listErrorSubject.send(failure)

        // then
        await waitUntil { sut.refreshNote != nil }
        #expect(sut.refreshNote?.message == failure.displayMessage)
        #expect(sut.refreshNote?.message.contains("denied") == false)
        #expect(sut.refreshNote?.message == "harflow-ctl refused the request.")
    }

    @Test func givenAnUnsupportedCommandListError_whenObserved_thenTheNoteShowsItsSentence() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        let failure = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-list-page", detail: "unrecognized")

        // when
        harness.listErrorSubject.send(failure)

        // then
        await waitUntil { sut.refreshNote != nil }
        #expect(sut.refreshNote?.message == failure.displayMessage)
        #expect(sut.isConnected == false)
    }

    @Test func givenManagedRuntimeUnavailable_whenObserved_thenNoRefreshNote() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)

        // when
        harness.listErrorSubject.send(.refused(code: "managed_runtime_preparing", message: "Preparing."))
        await waitUntil { !sut.isConnected }

        // then
        #expect(sut.refreshNote == nil)
    }

    @Test func givenSuccessfulListingAfterFailure_whenObserved_thenNoteClears() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(.timedOut(tool: "harflow-ctl", seconds: 30))
        await waitUntil { sut.refreshNote != nil }

        // when
        harness.listErrorSubject.send(nil)

        // then
        await waitUntil { sut.refreshNote == nil }
        #expect(sut.refreshNote == nil)
    }

    @Test func givenARuntimeThatIsNotReady_whenAListErrorArrives_thenNoNoteShows() async {
        // given
        let harness = makeSUT(runtimeState: .installing)
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        await waitUntil { sut.isConnected }

        // when
        harness.listErrorSubject.send(.timedOut(tool: "harflow-ctl", seconds: 30))
        await waitUntil { !sut.isConnected }

        // then
        #expect(sut.refreshNote == nil)
    }

    @Test func givenRetryTapped_whenCalled_thenRefreshWorkRunsOnce() async {
        // given
        let harness = makeSUT()

        // when
        harness.sut.didTapRetryRefresh()

        // then
        await verify(harness.useCase).refreshWork().calledEventually(1, before: .seconds(5))
    }
}
