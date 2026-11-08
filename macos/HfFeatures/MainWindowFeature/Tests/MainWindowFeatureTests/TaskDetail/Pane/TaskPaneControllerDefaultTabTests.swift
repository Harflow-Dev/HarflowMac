import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - TaskPaneControllerDefaultTabTests

/// The default tab resolved with the open default: per status, the fallback before readiness, the shown tab that never
/// jumps, eviction while shown, and a person's choice winning.
@MainActor
struct TaskPaneControllerDefaultTabTests {
    private typealias Controller = TaskPaneController
    private static let conversation = "conv"

    private func make(store: TaskPaneStateStore = TaskPaneStateStore()) -> (Controller, TaskPaneStateStore) {
        (Controller(store: store, conversationID: Self.conversation), store)
    }

    private static func input(tab: TaskPaneStateStore.Tab, split: Bool = true) -> Controller.DefaultInput {
        Controller.DefaultInput(isReady: true, opensAtSplit: split, tab: tab)
    }

    @Test(arguments: [TaskPaneStateStore.Tab.changes, .events])
    func givenAReadyDefault_whenResolved_thenTheTabIsStoredAndShownOnceThePaneIsOpen(tab: TaskPaneStateStore.Tab) {
        // given
        let (sut, store) = make()

        // when
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.input(tab: tab))

        // then
        #expect(sut.appliedDefaultTab == tab)
        #expect(store.appliedDefaultTab(for: Self.conversation) == tab)
        #expect(sut.selectedTab == tab)
        #expect(store.selectedTab(for: Self.conversation) == nil, "a default is not a person's choice")
    }

    @Test func givenTheDefaultIsNotReady_whenRead_thenEventsShowsAndNothingIsStored() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1280)

        // when
        sut.updateDefaultInput(Controller.DefaultInput(isReady: false, opensAtSplit: true, tab: .changes))

        // then
        #expect(sut.selectedTab == .events)
        #expect(sut.appliedDefaultTab == nil)
        #expect(store.appliedDefaultTab(for: Self.conversation) == nil)
    }

    @Test func givenAPaneShownOnTheFallbackTabBeforeReadiness_whenTheDefaultBecomesReady_thenTheShownTabBecomesTheDefault() {
        // given: the person opened the pane while the default was not ready, so Events was shown
        let (sut, store) = make()
        sut.updateContainerWidth(1280)
        sut.open()
        #expect(sut.selectedTab == .events)

        // when: the default turns out to be Changes
        sut.updateDefaultInput(Self.input(tab: .changes))

        // then: the tab does not jump
        #expect(sut.selectedTab == .events)
        #expect(sut.appliedDefaultTab == .events)
        #expect(store.appliedDefaultTab(for: Self.conversation) == .events)
    }

    @Test func givenAClosedPane_whenTheDefaultBecomesReady_thenTheResolvedTabIsTheDefaultOne() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.close()

        // when
        sut.updateDefaultInput(Self.input(tab: .changes))

        // then
        #expect(sut.appliedDefaultTab == .changes)
    }

    @Test func givenAnAppliedDefault_whenAPersonSelectsATab_thenTheirChoiceWinsAndTheDefaultStays() {
        // given
        let (sut, store) = make()
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.input(tab: .changes))

        // when
        sut.select(.artifacts)

        // then
        #expect(sut.selectedTab == .artifacts)
        #expect(store.selectedTab(for: Self.conversation) == .artifacts)
        #expect(sut.appliedDefaultTab == .changes)
    }

    @Test func givenAnAppliedDefault_whenLaterInputChanges_thenItIsNotResolvedAgain() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.input(tab: .events, split: false))

        // when: the task finishes after the first show
        sut.updateDefaultInput(Self.input(tab: .changes))

        // then
        #expect(sut.appliedDefaultTab == .events)
        #expect(sut.appliedDefaultOpen == false)
    }

    @Test func givenAnEvictedStoreEntryWhileShown_whenRead_thenTheViewLocalCopyKeepsTheDefaultTab() {
        // given: enough other conversations to push the first out of the bounded store
        let store = TaskPaneStateStore()
        let (sut, _) = make(store: store)
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.input(tab: .changes))
        #expect(sut.selectedTab == .changes)

        // when
        for index in 0 ..< TaskPaneStateStore.capacity { store.setOpenChoice(.open, for: "other-\(index)") }

        // then
        #expect(store.appliedDefaultTab(for: Self.conversation) == nil)
        #expect(sut.appliedDefaultTab == .changes)
        #expect(sut.selectedTab == .changes)
    }

    @Test func givenARevisit_whenTheControllerIsRebuilt_thenItReadsTheStoredDefaultTab() {
        // given
        let (first, store) = make()
        first.updateContainerWidth(1280)
        first.updateDefaultInput(Self.input(tab: .changes))

        // when
        let second = Controller(store: store, conversationID: Self.conversation)

        // then
        #expect(second.appliedDefaultTab == .changes)
        #expect(second.selectedTab == .changes)
    }

    @Test func givenAChangesDefault_whenAFactsGroupIsRevealed_thenEventsIsForcedAndTheDefaultIsKept() {
        // given
        let (sut, _) = make()
        sut.updateContainerWidth(1280)
        sut.updateDefaultInput(Self.input(tab: .changes))

        // when
        sut.revealFacts(group: .notices)

        // then
        #expect(sut.selectedTab == .events)
        #expect(sut.appliedDefaultTab == .changes)
    }
}
