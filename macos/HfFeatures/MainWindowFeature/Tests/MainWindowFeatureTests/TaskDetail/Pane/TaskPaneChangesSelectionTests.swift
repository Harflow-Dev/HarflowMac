import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskPaneChangesSelectionTests

/// The remembered Changes row, kept per conversation by the pane store and reached through the controller.
@MainActor
struct TaskPaneChangesSelectionTests {
    private static let conversation = "conv"
    private let selection = TaskChangesSelection(taskID: "t1", selector: ChangesJSON.selector("src/app.py", scope: .workingTree))

    // MARK: Store

    @Test func givenAnEmptyStore_whenTheSelectionIsRead_thenThereIsNone() {
        // given / when / then
        #expect(TaskPaneStateStore().changesSelection(for: "a") == nil)
    }

    @Test func givenASelection_whenStored_thenItIsKeptPerConversationAndClearable() {
        // given
        let sut = TaskPaneStateStore()

        // when
        sut.setChangesSelection(selection, for: "a")

        // then
        #expect(sut.changesSelection(for: "a") == selection)
        #expect(sut.changesSelection(for: "b") == nil)
        #expect(sut.hasEntry(for: "a"))

        // when
        sut.setChangesSelection(nil, for: "a")

        // then
        #expect(sut.changesSelection(for: "a") == nil)
    }

    @Test func givenClearingAnUnknownConversation_whenWritten_thenNoEntryIsCreated() {
        // given
        let sut = TaskPaneStateStore()
        // when
        sut.setChangesSelection(nil, for: "a")
        // then
        #expect(!sut.hasEntry(for: "a"))
    }

    @Test func givenTheSameSelection_whenWrittenAgain_thenNoObservationNotificationFires() {
        // given
        let sut = TaskPaneStateStore()
        sut.setChangesSelection(selection, for: "a")
        let flag = ChangesObservationFlag()
        withObservationTracking { _ = sut.changesSelection(for: "a") } onChange: { flag.set() }

        // when
        sut.setChangesSelection(selection, for: "a")

        // then
        #expect(!flag.isSet)
    }

    @Test func givenTheStoredSelection_whenDescribed_thenItIsAddressOnlyAndHoldsNoDiffText() {
        // given
        let sut = TaskPaneStateStore()
        sut.setChangesSelection(selection, for: "a")
        // when
        let printed = String(describing: sut.changesSelection(for: "a") as Any)
        // then
        #expect(printed.contains("src/app.py") || printed.contains("TaskChangesSelection"))
        #expect(!printed.contains("@@"))
    }

    @Test func givenMoreConversationsThanTheCapacity_whenSelectionsAreStored_thenTheOldestIsEvicted() {
        // given
        let sut = TaskPaneStateStore()
        sut.setChangesSelection(selection, for: "first")

        // when
        for index in 0 ..< TaskPaneStateStore.capacity { sut.setChangesSelection(selection, for: "other-\(index)") }

        // then
        #expect(sut.changesSelection(for: "first") == nil)
        #expect(sut.changesSelection(for: "other-0") == selection)
    }

    // MARK: Controller

    @Test func givenAController_whenASelectionIsRecorded_thenItReadsBackAndTheStoreHoldsIt() {
        // given
        let store = TaskPaneStateStore()
        let sut = TaskPaneController(store: store, conversationID: Self.conversation)
        #expect(sut.changesSelection == nil)

        // when
        sut.recordChangesSelection(selection)

        // then
        #expect(sut.changesSelection == selection)
        #expect(store.changesSelection(for: Self.conversation) == selection)

        // when
        sut.recordChangesSelection(nil)

        // then
        #expect(sut.changesSelection == nil)
    }

    @Test func givenARevisit_whenTheControllerIsRebuilt_thenTheRememberedSelectionIsOffered() {
        // given
        let store = TaskPaneStateStore()
        TaskPaneController(store: store, conversationID: Self.conversation).recordChangesSelection(selection)

        // when
        let revisit = TaskPaneController(store: store, conversationID: Self.conversation)

        // then
        #expect(revisit.changesSelection == selection)
    }
}
