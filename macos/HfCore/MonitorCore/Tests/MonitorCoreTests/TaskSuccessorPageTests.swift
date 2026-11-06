import Foundation
@testable import MonitorCore
import Testing

struct TaskSuccessorPageTests {
    private func page() -> [String: JSONValue] {
        ["successor_scope": .string("recorded_tasks"), "predecessor_task_id": .string("root"),
         "items": .array([.object(["task_id": .string("outside-window"), "session_id": .string("another-session"),
                                  "continuation_of_task_id": .string("root")])]),
         "has_more": .bool(false), "bootstrap_pending": .bool(false), "next_cursor": .null]
    }

    @Test func givenCrossSessionContinuation_whenDecoded_thenDirectSuccessorIsPreserved() throws {
        // given / when
        let result = try #require(TaskSuccessorPage(raw: page(), predecessorTaskID: "root"))
        // then
        #expect(result.history.items.map(\.taskID) == ["outside-window"])
        #expect(result.history.items.first?.sessionID == "another-session")
    }

    @Test(arguments: ["successor_scope", "predecessor_task_id", "items", "history_incomplete", "authority_incomplete",
                      "counts_complete", "catalog_state", "total_active_count"])
    func givenMalformedProvenanceOrMetadata_whenDecoded_thenRefused(field: String) {
        // given
        var raw = page()
        raw[field] = .string("invalid")
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }

    @Test func givenSpawnedChildOrWrongDirectEdge_whenDecoded_thenNotAcceptedAsSuccessor() {
        // given
        var raw = page()
        raw["items"] = .array([.object(["task_id": .string("child"), "spawned_by": .string("root")])])
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }

    @Test func givenPresentNonIntegerCounterOrUnknownCatalogStatus_whenDecoded_thenRefused() {
        // given
        var raw = page()
        raw["total_active_count"] = .number(1, isInteger: false)
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
        raw = page()
        raw["catalog_state"] = .object(["status": .string("future"), "source": .string("catalog"),
                                        "pending_records": .number(0), "blocked_records": .number(0)])
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }

    @Test func givenOversizedRowAndRepeatedIDs_whenDecoded_thenRefused() {
        // given
        var raw = page()
        let item = raw["items"]!.arrayValue![0]
        raw["items"] = .array([item, item])
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
        raw = page()
        raw["next_cursor"] = .string(String(repeating: "x", count: 2049))
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }
}

extension TaskSuccessorPageTests {
    @Test func givenAggregateRowsExceedProducerBudget_whenEachRowFits_thenEntirePageIsRefused() {
        // given
        var raw = page()
        raw["items"] = .array((0 ..< 3).map { index in .object(["task_id": .string("row-\(index)"),
            "parent_task_id": .string("root"), "text": .string(String(repeating: "x", count: 45000))]) })
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }

    @Test func givenUnicodeRows_whenAsciiEscapingExceedsProducerBudget_thenRefused() {
        // given
        var raw = page()
        raw["items"] = .array([.object(["task_id": .string("unicode"), "parent_task_id": .string("root"),
            "text": .string(String(repeating: "💡", count: 12000))])])
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }

    @Test func givenCanonicalCursorBoundary_whenDecoded_thenOnlyAtMost2048CharactersAccepted() {
        // given
        var raw = page()
        raw["has_more"] = .bool(true)
        raw["next_cursor"] = .string(String(repeating: "x", count: 2048))
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") != nil)
        raw["next_cursor"] = .string(String(repeating: "x", count: 2049))
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }
}

extension TaskSuccessorPageTests {
    @Test func givenDELText_whenProducerEscapingExceedsAggregateRowBudget_thenRefusedBelowDocumentBudget() {
        // given: 22000 DEL scalars become 132000 ASCII bytes in producer row payloads.
        var raw = page()
        raw["items"] = .array([.object(["task_id": .string("del"), "parent_task_id": .string("root"),
            "text": .string(String(repeating: "\u{007F}", count: 22000))])])
        #expect(JSONValue.object(raw).rendered().utf8.count < 256 * 1024)
        // when / then
        #expect(TaskSuccessorPage(raw: raw, predecessorTaskID: "root") == nil)
    }
}
