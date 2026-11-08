//
//  TaskPaneControllerRevealTests.swift
//  MainWindowFeatureTests
//

import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskPaneControllerRevealTests

/// The reveal route, the pending focus request, the Escape order and the focus return of `TaskPaneController`.
@MainActor
struct TaskPaneControllerRevealTests {
    private typealias Controller = TaskPaneController
    private static let conversation = "conv"

    private func make(id: String = conversation, store: TaskPaneStateStore = TaskPaneStateStore()) -> (Controller, TaskPaneStateStore) {
        (Controller(store: store, conversationID: id), store)
    }

    // MARK: - Reveal

    @Test func givenAClosedPaneAtOverlayWidth_whenRevealing_thenItOpensOnEventsWithTheGroupExpandedAndAFocusRequest() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(700)
        sut.select(.artifacts)
        sut.close()

        // when
        sut.revealFacts(group: .continuity, origin: .continuityDetails)

        // then
        #expect(sut.isOpen)
        #expect(sut.selectedTab == .events)
        #expect(store.selectedTab(for: Self.conversation) == .events)
        #expect(sut.expandedGroups.contains(.continuity))
        #expect(sut.isRevealed)
        #expect(sut.revealOrigin == .continuityDetails)
        #expect(sut.focusRequest?.group == .continuity)
    }

    @Test func givenTwoReveals_whenRequested_thenTheTokenGrowsAndTheOlderTokenCannotClearTheNewer() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)
        let first = sut.focusRequest?.token
        sut.revealFacts(group: .continuity, origin: .continuityDetails)
        let second = sut.focusRequest?.token

        // when
        sut.consumeFocusRequest(token: first ?? -1)

        // then
        #expect(first != nil && second != nil && second! > first!)
        #expect(sut.focusRequest?.token == second)

        // when
        sut.consumeFocusRequest(token: second ?? -1)

        // then
        #expect(sut.focusRequest == nil)
    }

    @Test func givenARevealWithoutAnOrigin_whenRevealing_thenThereIsNoOriginAndNoFocusReturnOnClose() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .task)

        // when
        sut.close()

        // then
        #expect(sut.revealOrigin == nil)
        #expect(sut.focusReturn == nil)
    }

    // MARK: - Pending focus request

    @Test func givenAPendingFocusRequest_whenOpened_thenItIsCleared() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        sut.open()

        // then
        #expect(sut.focusRequest == nil)
        #expect(!sut.isRevealed)
        #expect(sut.revealOrigin == nil)
    }

    @Test func givenAPendingFocusRequest_whenClosed_thenItIsCleared() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        sut.close()

        // then
        #expect(sut.focusRequest == nil)
        #expect(!sut.isRevealed)
    }

    @Test func givenAPendingFocusRequest_whenATabIsSelected_thenItIsCleared() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        sut.select(.artifacts)

        // then
        #expect(sut.focusRequest == nil)
        #expect(!sut.isRevealed)
    }

    @Test func givenAPendingFocusRequest_whenToggledClosed_thenItIsCleared() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        sut.toggle()

        // then
        #expect(sut.focusRequest == nil)
    }

    @Test func givenAChangesSelection_whenARequestIsPending_thenTheRevealIsDropped() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        sut.select(.changes)

        // then
        #expect(sut.focusRequest == nil)
        #expect(!sut.isRevealed)
        #expect(sut.selectedTab == .changes)
    }

    // MARK: - Escape order

    @Test func givenAFocusedGroup_whenEscaping_thenFocusLeavesTheGroupAndThePaneStays() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(700)
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        let outcome = sut.handleEscape(groupFocused: true)

        // then
        #expect(outcome == .leftFactsGroup(.notices))
        #expect(sut.isOpen)
        #expect(sut.isRevealed)
        #expect(sut.focusReturn == nil)
    }

    @Test func givenAnOverlayPane_whenEscaping_thenItCloses() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(700)
        sut.open()

        // when
        let outcome = sut.handleEscape(groupFocused: false)

        // then
        #expect(outcome == .closedOverlay(nil))
        #expect(!sut.isOpen)
        #expect(store.openChoice(for: Self.conversation) == .closed)
    }

    @Test func givenARevealedOverlayPane_whenEscaping_thenTheOverlayRouteWinsAndFocusReturns() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(700)
        sut.revealFacts(group: .continuity, origin: .continuityDetails)

        // when
        let outcome = sut.handleEscape(groupFocused: false)

        // then
        #expect(outcome == .closedOverlay(.continuityDetails))
        #expect(sut.focusReturn == .continuityDetails)
    }

    @Test func givenARevealedSplitPane_whenEscaping_thenItClosesAfterTheReveal() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.revealFacts(group: .notices, origin: .notices)

        // when
        let outcome = sut.handleEscape(groupFocused: false)

        // then
        #expect(outcome == .closedAfterReveal(.notices))
        #expect(!sut.isOpen)
        #expect(sut.focusReturn == .notices)
    }

    @Test func givenASplitPaneThePersonOpened_whenEscaping_thenNothingHappens() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.open()

        // when
        let outcome = sut.handleEscape(groupFocused: false)

        // then
        #expect(outcome == .ignored)
        #expect(sut.isOpen)
    }

    @Test func givenARevealedSplitPaneThePersonThenTabbed_whenEscaping_thenItIsNoLongerARevealAndNothingHappens() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.revealFacts(group: .notices, origin: .notices)
        sut.select(.artifacts)

        // when
        let outcome = sut.handleEscape(groupFocused: false)

        // then
        #expect(outcome == .ignored)
        #expect(sut.isOpen)
    }

    @Test func givenAClosedPane_whenEscaping_thenItIsIgnored() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(700)

        // when / then
        #expect(sut.handleEscape(groupFocused: false) == .ignored)
    }

    @Test func givenAFocusedGroupAndAClosedPane_whenEscaping_thenTheGroupRouteStillWins() {
        // given
        let (sut, _) = make()

        // when / then
        #expect(sut.handleEscape(groupFocused: true) == .leftFactsGroup(nil))
    }

    // MARK: - Focus return on every close route

    @Test func givenARevealedPane_whenClosedByEachRoute_thenFocusReturnsToTheOrigin() {
        for origin in [Controller.Origin.continuityDetails, .notices] {
            // close button
            let (button, _) = make()
            button.updateContainerWidth(1280)
            button.revealFacts(group: .notices, origin: origin)
            button.close()
            #expect(button.focusReturn == origin)

            // toolbar toggle
            let (toggle, _) = make()
            toggle.updateContainerWidth(1280)
            toggle.revealFacts(group: .notices, origin: origin)
            toggle.toggle()
            #expect(toggle.focusReturn == origin)

            // escape at overlay
            let (overlay, _) = make()
            overlay.updateContainerWidth(600)
            overlay.revealFacts(group: .notices, origin: origin)
            _ = overlay.handleEscape(groupFocused: false)
            #expect(overlay.focusReturn == origin)

            // escape at split
            let (split, _) = make()
            split.updateContainerWidth(1280)
            split.revealFacts(group: .notices, origin: origin)
            _ = split.handleEscape(groupFocused: false)
            #expect(split.focusReturn == origin)
        }
    }

    @Test func givenAPaneThePersonOpened_whenClosed_thenNoFocusReturnIsRequested() {
        // given
        let (sut, _) = make()
        sut.open()

        // when
        sut.close()

        // then
        #expect(sut.focusReturn == nil)
    }

    @Test func givenAPendingFocusReturn_whenAnyPersonActionFollows_thenItIsCleared() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)
        sut.close()
        #expect(sut.focusReturn == .notices)

        // when
        sut.open()

        // then
        #expect(sut.focusReturn == nil)

        // given
        sut.revealFacts(group: .notices, origin: .notices)
        sut.close()

        // when
        sut.select(.events)

        // then
        #expect(sut.focusReturn == nil)
    }

    @Test func givenAFocusReturn_whenConsumed_thenItIsDropped() {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)
        sut.close()

        // when
        sut.consumeFocusReturn()

        // then
        #expect(sut.focusReturn == nil)
    }

    // MARK: - Superseded deferred requests

    @Test func givenARevealFollowedByAClose_whenTheDeferredWorkChecks_thenItDoesNotAct() throws {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)
        let token = try #require(sut.focusRequest?.token)
        #expect(sut.isCurrentReveal(token: token))

        // when
        sut.close()

        // then
        #expect(!sut.isCurrentReveal(token: token))
        #expect(sut.focusRequest == nil)
    }

    @Test func givenARevealFollowedByATabSwitch_whenTheDeferredWorkChecks_thenItDoesNotAct() throws {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .continuity, origin: .continuityDetails)
        let token = try #require(sut.focusRequest?.token)

        // when
        sut.select(.artifacts)

        // then — the pane is open on Artifacts, so neither the stale scroll nor the focus may land
        #expect(sut.isOpen)
        #expect(sut.selectedTab == .artifacts)
        #expect(!sut.isCurrentReveal(token: token))
    }

    @Test func givenARevealFollowedByASecondReveal_whenTheDeferredWorkChecks_thenOnlyTheNewestActs() throws {
        // given
        let (sut, _) = make()
        sut.revealFacts(group: .notices, origin: .notices)
        let first = try #require(sut.focusRequest?.token)

        // when
        sut.revealFacts(group: .continuity, origin: .continuityDetails)
        let second = try #require(sut.focusRequest?.token)

        // then
        #expect(second > first)
        #expect(!sut.isCurrentReveal(token: first))
        #expect(sut.isCurrentReveal(token: second))
        #expect(sut.focusRequest?.group == .continuity)
        #expect(sut.revealOrigin == .continuityDetails)

        // when — the stale request finishes first, the newest request is still pending
        sut.consumeFocusRequest(token: first)

        // then
        #expect(sut.isCurrentReveal(token: second))
    }

    @Test func givenARevealFollowedByAnEscapeThatClosesIt_whenTheDeferredWorkChecks_thenItDoesNotAct() throws {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(700)
        sut.revealFacts(group: .notices, origin: .notices)
        let token = try #require(sut.focusRequest?.token)

        // when
        _ = sut.handleEscape(groupFocused: false)

        // then
        #expect(!sut.isOpen)
        #expect(!sut.isCurrentReveal(token: token))
    }
}
