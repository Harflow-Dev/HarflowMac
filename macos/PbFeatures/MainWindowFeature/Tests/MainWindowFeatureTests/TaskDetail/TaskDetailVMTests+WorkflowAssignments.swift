import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - TaskDetailVMTests workflow assignments

@MainActor
extension TaskDetailVMTests {
    @Test(arguments: [true, false])
    func givenOrchestratorDecisions_whenOpened_thenOnlySameHarnessSessionHistoryIsCombined(sameSession: Bool) async throws {
        // given
        let members = try (0 ..< 5).map { index in
            var raw = conversationTask("decision-\(index)", minute: index).raw
            raw["workflow_run_id"] = .string("run")
            raw["workflow_role"] = .string("orchestrator")
            raw["execution_contract"] = .string("delegation")
            raw["session_id"] = .string(sameSession ? "shared-session" : "fresh-session-\(index)")
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
        let expected = sameSession ? members : [members[0]]
        await waitUntil { harness.sut.timelineModel.rows.filter { if case .item = $0.kind { return true }; return false }.count == expected.count }
        // then
        #expect(harness.sut.conversationMembers.map(\.taskID) == expected.map(\.taskID))
        #expect(Set(harness.sut.timelineModel.rows.map(\.taskID)) == Set(expected.map(\.taskID)))
        #expect(harness.sut.turnsText == (sameSession ? "5 decisions" : nil))
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

extension TaskDetailVMTests {
    @Test func givenResumedSameSessionNode_whenOpened_thenAssignmentsRemainDistinctInOneHistory() async throws {
        // given
        let members = try (0 ..< 2).map { index in
            var raw = conversationTask("attempt-\(index)", minute: index).raw
            raw["workflow_run_id"] = .string("run")
            raw["workflow_role"] = .string("node")
            raw["workflow_node_id"] = .string("planning")
            raw["execution_contract"] = .string("delegation")
            raw["display_prompt"] = .string("Assignment \(index)")
            return try #require(TaskInfo(.object(raw)))
        }
        let harness = makeConversationSUT(openedAs: "attempt-0", initialMembers: members)
        for (index, member) in members.enumerated() {
            let event: [String: JSONValue] = ["v": .number(1), "seq": .number(1), "kind": .string("user_message"),
                "source": .string("initial"), "text": .string("Assignment \(index)")]
            harness.eventsBox[member.taskID]?.value = [try #require(TaskEvent(line: JSONValue.object(event).rendered()))]
        }
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { harness.sut.task?.taskID == "attempt-1" }
        // then
        #expect(harness.sut.conversationMembers.map(\.taskID) == ["attempt-0", "attempt-1"])
        #expect(harness.sut.promptText == "Assignment 1")
        #expect(Set(harness.sut.timelineModel.rows.map(\.taskID)) == ["attempt-0", "attempt-1"])
        harness.sut.didDisappear()
    }

    @Test func givenEmbeddedBuilderFollowup_whenOpenedThroughOriginalTask_thenResumedTurnsStayVisible() async throws {
        // given
        let members = try (0 ..< 2).map { index in
            var raw = conversationTask("builder-\(index)", parentTaskID: index == 0 ? nil : "builder-0", minute: index).raw
            raw["workflow_run_id"] = .string("builder-run")
            raw["workflow_builder"] = .bool(true)
            return try #require(TaskInfo(.object(raw)))
        }
        let harness = makeConversationSUT(openedAs: "builder-0", initialMembers: members, isWorkflowBuilder: true)
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send(members)
        await waitUntil { harness.sut.task?.taskID == "builder-1" }
        // then
        #expect(harness.sut.conversationMembers.count == 2)
        harness.sut.didDisappear()
    }
}
