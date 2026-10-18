import Foundation
@testable import MonitorCore
import Testing

struct WorkflowArtifactPageTests {
    private func item(taskID: String = "worker", artifactID: String = "artifact", workflow: [String: Any]? = nil) throws -> JSONValue {
        var value: [String: Any] = [
            "artifact_id": artifactID, "task_id": taskID, "kind": "report", "path": "/repo/report",
            "note": "  exact\nnote  ", "registered_at": "now",
            "provenance": ["method": "verified_process_lineage", "task_id": taskID],
            "availability": ["state": "changed", "observed_at": "later"]
        ]
        if let workflow { value["workflow"] = workflow }
        return try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: value))
    }

    private func binding(taskID: String = "worker") -> [String: Any] {
        ["root_workflow_run_id": "root", "workflow_run_id": "run", "node_id": "work", "execution_id": "exec",
         "role": "node", "task_id": taskID, "attribution": "attempt", "provenance": "workflow_receipt"]
    }

    @Test func givenWorkflowBinding_whenDecoded_thenRoleAndVerbatimNoteSurvive() throws {
        let rawItem = try item(workflow: binding())
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "items": .array([rawItem]),
            "owners": .array([]), "next_cursor": .null, "has_more": .bool(false), "state": .string("available")]
        let page = try #require(WorkflowArtifactPage(raw: raw, runID: "run"))
        #expect(page.items.first?.workflow?.executionID == "exec")
        #expect(page.items.first?.note == "  exact\nnote  ")
        #expect(page.items.first?.availability == "changed")
    }

    @Test func givenMissingOrMismatchedBinding_whenDecoded_thenPageIsRejected() throws {
        let unbound = try item()
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "items": .array([unbound]),
            "owners": .array([]), "next_cursor": .null, "has_more": .bool(false), "state": .string("available")]
        #expect(WorkflowArtifactPage(raw: raw, runID: "run") == nil)

        let mismatched = try item(workflow: binding(taskID: "other"))
        let changed = raw.merging(["items": .array([mismatched])]) { _, new in new }
        #expect(WorkflowArtifactPage(raw: changed, runID: "run") == nil)
    }

    @Test func givenOwnerDiagnostics_whenDecoded_thenOnlyBoundedStatesAreAccepted() throws {
        let owner: [String: JSONValue] = ["workflow_run_id": .string("run"), "task_id": .string("missing"), "state": .string("record_removed")]
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "items": .array([]),
            "owners": .array([.object(owner)]), "next_cursor": .null, "has_more": .bool(false), "state": .string("available")]
        let page = try #require(WorkflowArtifactPage(raw: raw, runID: "run"))
        #expect(page.owners.first?.state == "record_removed")
    }

    @Test func givenDuplicateItemsOrOversizedCursor_whenDecoded_thenPageIsRejected() throws {
        let first = try item()
        let raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "items": .array([first, first]),
            "owners": .array([]), "next_cursor": .string("cursor"), "has_more": .bool(true), "state": .string("available")]
        #expect(WorkflowArtifactPage(raw: raw, runID: "run") == nil)
        var oversized = raw
        oversized["items"] = .array([first])
        oversized["next_cursor"] = .string(String(repeating: "x", count: 513))
        #expect(WorkflowArtifactPage(raw: oversized, runID: "run") == nil)
    }
}
