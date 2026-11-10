import Foundation
@testable import MainWindowFeature
import Observation
import os
import Testing

// MARK: - TaskPaneObservationTests

/// Checks the Observation boundary a mounted pane relies on when a persisted tab changes independently of the controller.
@MainActor struct TaskPaneObservationTests {
    private final class Counter: Sendable {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var value: Int { count.withLock { $0 } }
        func increment() { count.withLock { $0 += 1 } }
    }

    @Test func givenAControllerSelectedTabReader_whenTheStoreTabChanges_thenObservationInvalidatesTheReader() {
        // given
        let store = TaskPaneStateStore()
        store.setSelectedTab(.events, for: "conversation")
        let controller = TaskPaneController(store: store, conversationID: "conversation")
        let changes = Counter()
        withObservationTracking {
            #expect(controller.selectedTab == .events)
        } onChange: {
            changes.increment()
        }

        // when
        store.setSelectedTab(.artifacts, for: "conversation")

        // then — distinguish a stale computed read from a missing observation notification.
        #expect(controller.selectedTab == .artifacts)
        #expect(changes.value == 1)
    }

    @Test func givenADirectStoreTabReader_whenTheStoreTabChanges_thenObservationInvalidatesTheReader() {
        // given
        let store = TaskPaneStateStore()
        store.setSelectedTab(.events, for: "conversation")
        let changes = Counter()
        withObservationTracking {
            #expect(store.selectedTab(for: "conversation") == .events)
        } onChange: {
            changes.increment()
        }

        // when
        store.setSelectedTab(.artifacts, for: "conversation")

        // then — the direct read is the control for the controller's nested read above.
        #expect(store.selectedTab(for: "conversation") == .artifacts)
        #expect(changes.value == 1)
    }
}
