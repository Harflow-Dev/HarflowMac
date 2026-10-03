import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

extension ParallelVMTests {
    @Test func givenWorkflowAssociations_whenTasksResume_thenExistingConversationFeedAndLeasesAreReused() async {
        // given
        let harness = makeSUT()
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 10), group: nil)
        let resumed = task(id: "resumed", startedAt: Date(timeIntervalSince1970: 20), group: nil, parentTaskID: "first")
        let unrelated = task(id: "unrelated")
        harness.tasksBox.value = [first.taskID: first, resumed.taskID: resumed, unrelated.taskID: unrelated]
        harness.sut.setWorkflowTaskIDs(["first", "resumed"], focusedTaskIDs: ["resumed"], titles: ["resumed": "Implement · 2"])
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([first, resumed, unrelated])
        await waitUntil { harness.sut.columns.count == 1 }
        // then
        #expect(harness.sut.columns.first?.task.taskID == "resumed")
        #expect(harness.sut.columns.first?.title == "Implement · 2")
        #expect(Set(harness.leasesBox.value.keys) == ["first", "resumed"])
        harness.sut.didDisappear()
        #expect(harness.releasedBox.value == ["first", "resumed"])
    }

    @Test func givenDisappearedWorkflow_whenMembershipUpdates_thenItDoesNotReacquireFeedsUntilAppearance() async {
        // given
        let harness = makeSUT()
        let member = task(id: "member", group: nil)
        harness.tasksBox.value = [member.taskID: member]
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        harness.sut.didDisappear()
        // when
        harness.sut.setWorkflowTaskIDs(["member"])
        // then
        #expect(harness.leasesBox.value.isEmpty)
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.columns.count == 1 }
        #expect(harness.leasesBox.value["member"] != nil)
        harness.sut.didDisappear()
    }

    @Test(arguments: [true, false])
    func givenWorkerContract_whenParallelColumnBuilt_thenOnlyDelegationWorkerProjectsResult(delegation: Bool) async throws {
        // given
        let harness = makeSUT()
        let contract = "{\"status\":\"succeeded\",\"result\":{\"summary\":\"Implemented feature\"},\"evidence\":[]}"
        var raw = task(id: "worker", status: "completed").raw
        raw["workflow_role"] = .string("node")
        raw["execution_contract"] = .string(delegation ? "delegation" : "historical")
        raw["display_prompt"] = .string("Focused assignment")
        raw["summary"] = .string(contract)
        let worker = try #require(TaskInfo(.object(raw)))
        let event = try #require(TaskEvent(line: JSONValue.object(["v": .number(1), "seq": .number(1),
                                                                 "kind": .string("assistant_text"), "text": .string(contract)])
.rendered()))
        harness.tasksBox.value = ["worker": worker]
        harness.itemsBox.value = ["worker": Timeline.items(from: [event])]
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([worker])
        harness.snapshotsSubject.send(["worker": worker])
        await waitUntil { harness.sut.columns.first?.summary != nil }
        // then
        let column = try #require(harness.sut.columns.first)
        #expect(column.prompt == "Focused assignment")
        #expect(column.summary == (delegation ? "Succeeded\n\nSummary: Implemented feature" : contract))
        let texts = column.rows.compactMap { row -> String? in
            guard case let .item(item) = row.kind, case let .text(text, _) = item.body else { return nil }
            return text
        }
        #expect(texts.contains(delegation ? "Succeeded\n\nSummary: Implemented feature" : contract))
        harness.sut.didDisappear()
    }

    @Test func givenResumedWorker_whenColumnBuilt_thenPromptShowsCurrentAssignment() async throws {
        // given
        let harness = makeSUT()
        var firstRaw = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 10)).raw
        firstRaw["display_prompt"] = .string("Original assignment")
        var currentRaw = task(id: "reply", startedAt: Date(timeIntervalSince1970: 20), parentTaskID: "first").raw
        currentRaw["display_prompt"] = .string("Current answer")
        currentRaw["workflow_role"] = .string("node")
        currentRaw["execution_contract"] = .string("delegation")
        let first = try #require(TaskInfo(.object(firstRaw)))
        let current = try #require(TaskInfo(.object(currentRaw)))
        harness.tasksBox.value = ["first": first, "reply": current]
        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([first, current])
        await waitUntil { harness.sut.columns.count == 1 }
        // then
        #expect(harness.sut.columns.first?.prompt == "Current answer")
        harness.sut.didDisappear()
    }

}
