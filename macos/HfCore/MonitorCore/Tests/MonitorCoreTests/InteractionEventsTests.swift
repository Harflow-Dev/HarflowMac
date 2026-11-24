import Foundation
@testable import MonitorCore
import Testing

@Suite
struct InteractionNotificationEventDecodingTests {
    private func row(_ extra: [String: JSONValue] = [:]) -> [String: JSONValue] {
        var row: [String: JSONValue] = [
            "event_id": .string("workflow:run-b:point-1:1:answered"), "state": .string("answered"),
            "kind": .string("question"), "title": .string("Release checklist"), "answer": .string("Use staging."),
            "answered_by": .string("monitor"), "occurred_at": .number(1_758_000_100)
        ]
        row.merge(extra) { _, new in new }
        return row
    }

    @Test func givenAnEngineRowWithCorrelationFields_whenDecoded_thenInteractionAndSourceIdsAreRead() throws {
        // given
        let raw = row([
            "workflow_run_id": .string("root-a"), "source_workflow_run_id": .string("run-b"),
            "interaction_id": .string("point-1"), "task_id": .null
        ])
        // when
        let event = try #require(InteractionNotificationEvent(raw))
        // then
        #expect(event.workflowRunID == "root-a")
        #expect(event.sourceWorkflowRunID == "run-b")
        #expect(event.interactionID == "point-1")
        #expect(event.taskID == nil)
    }

    @Test func givenARowWithoutCorrelationFields_whenDecoded_thenTheyAreNil() throws {
        // given / when
        let event = try #require(InteractionNotificationEvent(row(["workflow_run_id": .string("root-a")])))
        // then
        #expect(event.sourceWorkflowRunID == nil)
        #expect(event.interactionID == nil)
        #expect(event.workflowRunID == "root-a")
    }

    @Test func givenAnOversizedInteractionID_whenDecoded_thenTheRowStillDecodesWithoutIt() throws {
        // given
        let raw = row(["interaction_id": .string(String(repeating: "x", count: 1025))])
        // when
        let event = try #require(InteractionNotificationEvent(raw))
        // then
        #expect(event.interactionID == nil)
    }
}
