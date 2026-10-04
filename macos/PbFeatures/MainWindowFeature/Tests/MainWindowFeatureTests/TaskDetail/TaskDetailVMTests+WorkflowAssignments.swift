import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - TaskDetailVMTests workflow assignments

@MainActor
extension TaskDetailVMTests {
    @Test func givenFiveFreshOrchestratorDecisions_whenLogicalChildOpened_thenEveryDecisionActivityRemainsInspectable() async throws {
        // given
        let members = try (0 ..< 5).map { index in
            var raw = conversationTask("decision-\(index)", minute: index).raw
            raw["workflow_run_id"] = .string("run")
            raw["workflow_role"] = .string("orchestrator")
            raw["execution_contract"] = .string("delegation")
            raw["session_id"] = .string("fresh-session-\(index)")
            return try #require(TaskInfo(.object(raw)))
        }
        let harness = makeConversationSUT(openedAs: "decision-0", initialMembers: members)
        for member in members {
            let event: [String: JSONValue] = ["v": .number(1), "seq": .number(1), "kind": .string("assistant_text"),
                                               "text": .string("Activity from " + member.taskID)]
            harness.eventsBox[member.taskID]?.value = [try #require(TaskEvent(line: JSONValue.object(event).rendered()))]
        }
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { harness.sut.timelineModel.rows.filter { if case .item = $0.kind { return true }; return false }.count == 5 }
        // then
        #expect(harness.sut.conversationMembers.map(\.taskID) == members.map(\.taskID))
        #expect(Set(harness.sut.timelineModel.rows.map(\.taskID)) == Set(members.map(\.taskID)))
        #expect(harness.sut.turnsText == "5 decisions")
        harness.sut.didDisappear()
    }

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
