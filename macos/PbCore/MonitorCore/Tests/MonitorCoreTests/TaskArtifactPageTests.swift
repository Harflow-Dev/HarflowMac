import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskArtifactPageTests

struct TaskArtifactPageTests {
    private func page(taskID: String = "task", note: String = "Line one\n🙂 café", state: String = "available") throws -> [String: JSONValue] {
        let item: [String: Any] = [
            "artifact_id": "artifact", "task_id": taskID, "kind": "report", "path": "/tmp/report", "note": note, "registered_at": "now",
            "provenance": ["method": "verified_process_lineage", "task_id": taskID], "availability": ["state": state, "observed_at": "later"]
        ]
        let object: [String: Any] = ["task_id": taskID, "items": [item], "next_cursor": NSNull(), "has_more": false, "state": "available", "count": 1]
        return try JSONDecoder().decode([String: JSONValue].self, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func givenUnicodeNote_whenDecoded_thenFullVerbatimTextAndProvenanceSurvive() throws {
        // given
        let raw = try page()
        // when
        let value = try #require(TaskArtifactPage(raw: raw, taskID: "task"))
        // then
        #expect(value.items.first?.note == "Line one\n🙂 café")
        #expect(value.items.first?.registrar == "verified_process_lineage")
        #expect(value.items.first?.observedAt == "later")
    }

    @Test func givenDifferentTaskIdentity_whenDecoded_thenPageIsRejected() throws {
        // given
        let raw = try page(taskID: "other")
        // when / then
        #expect(TaskArtifactPage(raw: raw, taskID: "task") == nil)
    }

    @Test func givenLegacyEmptyPage_whenDecoded_thenEmptyIsAvailable() {
        // given
        let raw: [String: JSONValue] = ["task_id": .string("task"), "items": .array([]),
            "next_cursor": .null, "has_more": .bool(false), "state": .string("available"), "count": .number(0)]
        // when
        let value = TaskArtifactPage(raw: raw, taskID: "task")
        // then
        #expect(value?.items.isEmpty == true)
        #expect(value?.state == "available")
    }

    @Test func givenOversizedMetadataPage_whenDecoded_thenItIsRejected() throws {
        // given
        let raw = try page(note: String(repeating: "x", count: 65536))
        // when / then
        #expect(TaskArtifactPage(raw: raw, taskID: "task") == nil)
    }

    @Test func givenUnrecognizedAvailabilityOrMissingCursor_whenDecoded_thenPageIsRejected() throws {
        // given
        let raw = try page(state: "invented")
        // when / then
        #expect(TaskArtifactPage(raw: raw, taskID: "task") == nil)
        var missingCursor = try page()
        missingCursor["has_more"] = .bool(true)
        #expect(TaskArtifactPage(raw: missingCursor, taskID: "task") == nil)
    }
}
