import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - TaskDetailVMTests workflow assignments

@MainActor
extension TaskDetailVMTests {
    @Test func givenResumedWorkflowWorker_whenOpened_thenCurrentPromptAndDistinctHistoricalBubblesRemain() async throws {
        // given
        var firstRaw = conversationTask("a", minute: 0).raw
        firstRaw["workflow_role"] = .string("node")
        firstRaw["execution_contract"] = .string("delegation")
        firstRaw["display_prompt"] = .string("Original assignment")
        var currentRaw = conversationTask("b", parentTaskID: "a", minute: 1).raw
        currentRaw["workflow_role"] = .string("node")
        currentRaw["execution_contract"] = .string("delegation")
        currentRaw["display_prompt"] = .string("Answer to the worker question")
        let first = try #require(TaskInfo(.object(firstRaw)))
        let current = try #require(TaskInfo(.object(currentRaw)))
        let harness = makeConversationSUT(openedAs: "b", initialMembers: [first, current])
        for (id, text) in [("a", "Original assignment"), ("b", "Answer to the worker question")] {
            let event: [String: JSONValue] = ["v": .number(1), "seq": .number(1), "kind": .string("user_message"),
                                               "source": .string("initial"), "text": .string(text)]
            harness.eventsBox[id]?.value = [try #require(TaskEvent(line: JSONValue.object(event).rendered()))]
        }
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([first, current])
        await waitUntil { harness.sut.task != nil }
        // then
        #expect(harness.sut.promptText == "Answer to the worker question")
        let messages = harness.sut.timelineModel.rows.compactMap { row -> String? in
            if case let .separator(text) = row.kind { return text }
            if case let .item(item) = row.kind, case let .message(text, _) = item.body { return text }
            return nil
        }
        #expect(messages == ["Original assignment", "Answer to the worker question"])
        harness.sut.didDisappear()
    }
}
