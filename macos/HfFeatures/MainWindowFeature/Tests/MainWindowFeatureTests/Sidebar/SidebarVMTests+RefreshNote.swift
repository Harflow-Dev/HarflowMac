//
//  SidebarVMTests+RefreshNote.swift
//  MainWindowFeatureTests
//
//  The "Couldn't refresh your work" note: after the first listing, a listing error that no gate owns shows the note and
//  keeps the rows; before the first listing the first-listing gate owns it. Same harness and suite as SidebarVMTests.
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

    // MARK: - Refresh note

    private var timedOut: ToolError { .timedOut(tool: "harflow-ctl task-list-page", seconds: 30) }

    @Test func givenAListedSidebar_whenTheListingTimesOut_thenTheRefreshNoteShowsWithoutTheRawLine() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        await waitUntil { sut.isConnected }
        #expect(!sut.showsRefreshNote)
        // when
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.showsRefreshNote }
        // then
        #expect(sut.listErrorMessage == nil)
        #expect(!sut.showsSetupGate)
    }

    @Test func givenAListedSidebar_whenAnUnreadableAnswerFails_thenTheRefreshNoteShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        // when
        harness.listErrorSubject.send(.unreadable(tool: "harflow-ctl task-list-page", exitCode: 1, stderr: ""))
        await waitUntil { sut.showsRefreshNote }
        // then
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenTheRefreshNote_whenAListingSucceeds_thenTheNoteClears() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.showsRefreshNote }
        // when
        harness.listErrorSubject.send(nil)
        // then
        await waitUntil { !sut.showsRefreshNote }
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenNothingListedYet_whenTheListingFails_thenNoNoteShowsAndTheLineForwards() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        let error = timedOut
        // when
        harness.listErrorSubject.send(error)
        await waitUntil { sut.listErrorMessage != nil }
        // then
        #expect(!sut.showsRefreshNote)
        #expect(sut.listErrorMessage == error.message)
    }

    @Test func givenAFailureBeforeTheFirstListing_whenTheListingArrives_thenTheNoteReplacesTheLine() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.listErrorMessage != nil }
        // when
        harness.hasListedSubject.send(true)
        // then
        await waitUntil { sut.showsRefreshNote }
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenAListedSidebar_whenAContractOrCapabilityGateOwnsTheError_thenNoNoteShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        // when
        harness.listErrorSubject.send(givenContractError())
        await waitUntil { sut.showsSetupGate }
        // then
        #expect(!sut.showsRefreshNote)
        #expect(sut.listErrorMessage == nil)
    }

    @Test func givenAListedSidebar_whenTheStoreRefusesOrTheManagedRuntimeIsUnavailable_thenNoNoteShows() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        let storeRefusal = ToolError.structuredRefusal(
            code: "state_incompatible", message: "Unsupported state root: foreign store marker",
            data: ["reason": .string("foreign_store")])
        let runtimeUnavailable = ToolError.refused(code: "managed_runtime_preparing", message: "Preparing the runtime.")
        // when / then
        for error in [storeRefusal, runtimeUnavailable] {
            harness.listErrorSubject.send(error)
            await Task.yield()
            await waitUntil { sut.latestListError == error }
            #expect(!sut.showsRefreshNote)
            #expect(sut.listErrorMessage == nil)
        }
    }

    @Test func givenTheRefreshNote_whenAnotherPlainErrorReplacesTheFirst_thenNothingRepublishes() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.showsRefreshNote }
        let writes = sut.presentationWrites
        // when
        let next = ToolError.unreadable(tool: "harflow-ctl task-list-page", exitCode: 1, stderr: "")
        harness.listErrorSubject.send(next)
        await waitUntil { sut.latestListError == next }
        // then
        #expect(sut.showsRefreshNote)
        #expect(sut.presentationWrites == writes)
    }

    @Test func givenTheRefreshNote_whenRetryIsTapped_thenRoutingRetriesTheListingOnce() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.showsRefreshNote }
        // when
        sut.didTapRetryRefresh()
        // then
        verify(harness.routing).retryLoadingWork().called(1)
    }

    @Test func givenTheRefreshNote_whenItFlipsOnRepeatedly_thenOneAnnouncementPerTransitionIsPosted() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        var announced: [String] = []
        sut.announce = { announced.append($0) }
        sut.didAppear()
        harness.hasListedSubject.send(true)
        await waitUntil { sut.isConnected }
        // when — shown, replaced by another plain error, cleared, shown again
        harness.listErrorSubject.send(timedOut)
        await waitUntil { sut.showsRefreshNote }
        let next = ToolError.unreadable(tool: "harflow-ctl task-list-page", exitCode: 1, stderr: "")
        harness.listErrorSubject.send(next)
        await waitUntil { sut.latestListError == next }
        #expect(announced == ["Couldn't refresh your work"])
        harness.listErrorSubject.send(nil)
        await waitUntil { !sut.showsRefreshNote }
        harness.listErrorSubject.send(timedOut)
        await waitUntil { announced.count == 2 }
        // then
        #expect(announced == ["Couldn't refresh your work", "Couldn't refresh your work"])
    }
}
