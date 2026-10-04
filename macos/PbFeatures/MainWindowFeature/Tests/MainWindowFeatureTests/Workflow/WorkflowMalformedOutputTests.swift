import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowMalformedOutputTests

struct WorkflowMalformedOutputTests {
    @Test func givenMarkedMalformedTerminalOutput_whenProjected_thenRawBodyBecomesOneCompactErrorCell() throws {
        // given
        let body = "{\"result\":\"" + String(repeating: "X", count: 13000)
        let marked = try #require(TaskInfo(.object([
            "task_id": .string("node"), "status": .string("completed"),
            "workflow_result_error": .string("Expected a complete JSON object")
        ])))
        let rows = [
            row("comment", text: "Reading files"),
            ConversationTimelineRow(id: "tool", taskID: "node", timestamp: nil, kind: .item(PreviewFixtures.toolItem()), live: false),
            row("output-1", text: body), row("output-2", text: "trailing output")
        ]
        // when
        let visible = WorkflowNodePresentation.visibleRows(rows, tasks: ["node": marked])
        // then
        #expect(visible.count == 3)
        #expect(visible.first == rows.first)
        #expect(visible.last?.id == "node#workflow-output-error")
        guard case .item(let item) = visible.last?.kind, case .tool(let call, let result) = item.body else {
            Issue.record("Expected a compact malformed output cell"); return
        }
        #expect(call.tool == "Malformed output")
        #expect(call.category == "workflow_protocol_error")
        #expect(result?.ok == false)
        #expect(result?.outputTail == "Expected a complete JSON object")
        #expect(!call.inputPreview.contains(body))
        #expect(visible.last?.taskID == "node")
    }

    @Test func givenOrdinaryProseWithoutErrorMetadata_whenProjected_thenResponseIsUnchanged() throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("node"), "status": .string("completed")])))
        let prose = [row("reply", text: "Malformed output is something we should handle.")]
        // when / then
        #expect(WorkflowNodePresentation.visibleRows(prose, tasks: ["node": task]) == prose)
    }

    @Test func givenListingErrorAndPlainSnapshot_whenRefreshed_thenErrorAndBoundedSummaryStayVisible() throws {
        // given
        let listing = try #require(TaskInfo(.object(["task_id": .string("node"), "workflow_result_error": .string("Missing result field")])))
        let rawBody = String(repeating: "broken JSON ", count: 2000)
        let snapshot = try #require(TaskInfo(.object(["task_id": .string("node"), "summary": .string(rawBody)])))
        // when
        let merged = WorkflowNodePresentation.merged(snapshot, with: listing)
        let summary = WorkflowNodePresentation.summary(merged.summary, task: merged)
        // then
        #expect(summary == "Malformed output\n\nMissing result field")
        #expect(merged.summary == rawBody) // Durable data stays inspectable.
        #expect(ToolBucket(category: "workflow_protocol_error") == nil)
    }

    @Test func givenSameSessionRepair_whenProjected_thenFailedAndSuccessfulAttemptsRemainOneSessionWithDistinctRows() throws {
        // given
        let common: [String: JSONValue] = ["workflow_run_id": .string("run"), "workflow_node_id": .string("node"),
            "workflow_role": .string("node"), "backend": .string("claude"), "session_id": .string("session"), "status": .string("completed")]
        var firstRaw = common
        firstRaw["task_id"] = .string("first")
        firstRaw["workflow_result_error"] = .string("Expected JSON")
        let first = try #require(TaskInfo(.object(firstRaw)))
        var secondRaw = common
        secondRaw["task_id"] = .string("second")
        let second = try #require(TaskInfo(.object(secondRaw)))
        let malformed = ConversationTimelineRow(id: "first-reply", taskID: "first", timestamp: nil,
            kind: .item(PreviewFixtures.textItem("not JSON")), live: false)
        let valid = ConversationTimelineRow(id: "second-reply", taskID: "second", timestamp: nil,
            kind: .item(PreviewFixtures.textItem("Fixed response")), live: false)
        // when / then
        #expect(WorkflowOrchestratorConversation.conversations([first, second]).count == 1)
        let projected = WorkflowNodePresentation.visibleRows([malformed, valid], tasks: ["first": first, "second": second])
        #expect(projected.count == 2)
        #expect(projected.last == valid)
        #expect(projected.first?.id == "first#workflow-output-error")
    }

    @Test func givenNoticeAfterMalformedResponse_whenProjected_thenNoticeCannotExposeRawOutput() throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("node"), "workflow_result_error": .string("Missing evidence")])))
        let output = row("reply", text: String(repeating: "invalid", count: 2000))
        let notice = ConversationTimelineRow(id: "notice", taskID: "node", timestamp: nil,
            kind: .item(PreviewFixtures.noticeItem("Runtime notice", seq: 2)), live: false)
        // when
        let visible = WorkflowNodePresentation.visibleRows([output, notice], tasks: ["node": task])
        // then
        #expect(visible.count == 2)
        #expect(visible.last == notice)
        guard case .item(let item) = visible.first?.kind, case .tool = item.body else {
            Issue.record("Expected malformed cell before notice"); return
        }
    }

    @Test(arguments: ["tool", "notice", "empty"])
    func givenErrorBeforeTerminalTextRefresh_whenProjected_thenExistingEvidenceIsPreservedAndErrorAppended(kind: String) throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("node"), "workflow_result_error": .string("No valid final result")])))
        let item = kind == "tool" ? PreviewFixtures.toolItem() : PreviewFixtures.noticeItem("Runtime notice", seq: 1)
        let rows: [ConversationTimelineRow] = kind == "empty" ? [] : [
            ConversationTimelineRow(id: "evidence", taskID: "node", timestamp: nil, kind: .item(item), live: false)
        ]
        // when
        let visible = WorkflowNodePresentation.visibleRows(rows, tasks: ["node": task])
        // then
        #expect(visible.count == rows.count + 1)
        #expect(Array(visible.prefix(rows.count)) == rows)
        guard case .item(let error) = visible.last?.kind, case .tool(let call, _) = error.body else {
            Issue.record("Expected appended error cell"); return
        }
        #expect(call.tool == "Malformed output")
    }

    @Test func givenMetadataBeforeTextRefresh_whenFinalTextArrives_thenErrorCellIdentityRemainsStable() throws {
        // given
        let task = try #require(TaskInfo(.object(["task_id": .string("node"), "workflow_result_error": .string("Missing result")])))
        let evidence = ConversationTimelineRow(id: "tool", taskID: "node", timestamp: nil, kind: .item(PreviewFixtures.toolItem()), live: false)
        // when
        let before = WorkflowNodePresentation.visibleRows([evidence], tasks: ["node": task])
        let after = WorkflowNodePresentation.visibleRows([evidence, row("reply", text: "invalid")], tasks: ["node": task])
        // then
        #expect(before.first == evidence && after.first == evidence)
        #expect(before.last?.id == after.last?.id)
        #expect(before.count == 2 && after.count == 2)
    }

    private func row(_ id: String, text: String) -> ConversationTimelineRow {
        ConversationTimelineRow(id: id, taskID: "node", timestamp: nil, kind: .item(PreviewFixtures.textItem(text)), live: false)
    }
}
