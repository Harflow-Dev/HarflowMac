@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkMessageQueueTests

@MainActor
struct WorkMessageQueueTests {
    @Test func givenWorkflowMessageStates_whenProjected_thenOnlyQueuedItemsCanBeCancelled() {
        // given
        let raw: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("one"), "status": .string("queued"), "text": .string("  exact text  ")]),
            .object(["id": .string("two"), "status": .string("delivering")]),
            .object(["id": .string("three"), "status": .string("delivered")])])]
        // when
        let items = WorkMessageQueue.items(raw: raw)
        // then
        #expect(items.map(\.id) == ["one", "two", "three"])
        #expect(items.first?.text == "  exact text  ")
        #expect(items.map(\.canCancel) == [true, false, false])
    }
}
