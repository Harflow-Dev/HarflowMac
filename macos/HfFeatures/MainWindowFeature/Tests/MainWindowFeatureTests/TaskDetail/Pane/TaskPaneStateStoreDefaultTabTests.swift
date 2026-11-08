import Foundation
@testable import MainWindowFeature
import Observation
import Testing

// MARK: - TaskPaneStateStoreDefaultTabTests

/// The applied default tab and the optional person's choice, kept apart in the store.
@MainActor
struct TaskPaneStateStoreDefaultTabTests {

    @Test func givenAnAppliedDefaultTab_whenWritten_thenItIsStoredWithoutBecomingAChoice() {
        // given
        let sut = TaskPaneStateStore()

        // when
        sut.setAppliedDefaultTab(.changes, for: "a")

        // then
        #expect(sut.appliedDefaultTab(for: "a") == .changes)
        #expect(sut.selectedTab(for: "a") == nil)
        #expect(sut.hasEntry(for: "a"))
        #expect(sut.appliedDefaultTab(for: "b") == nil)
    }

    @Test func givenAPersonsChoice_whenAnotherTabIsTheDefault_thenBothAreKeptSeparately() {
        // given
        let sut = TaskPaneStateStore()

        // when
        sut.setSelectedTab(.artifacts, for: "a")
        sut.setAppliedDefaultTab(.events, for: "a")

        // then
        #expect(sut.selectedTab(for: "a") == .artifacts)
        #expect(sut.appliedDefaultTab(for: "a") == .events)
    }

    @Test func givenTheSameDefaultTab_whenWrittenAgain_thenNoObservationNotificationFires() {
        // given
        let sut = TaskPaneStateStore()
        sut.setAppliedDefaultTab(.changes, for: "a")
        let flag = ChangesObservationFlag()
        withObservationTracking { _ = sut.appliedDefaultTab(for: "a") } onChange: { flag.set() }

        // when
        sut.setAppliedDefaultTab(.changes, for: "a")

        // then
        #expect(!flag.isSet)
    }
}
