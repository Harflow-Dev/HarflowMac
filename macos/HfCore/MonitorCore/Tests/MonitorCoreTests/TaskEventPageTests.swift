import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskEventPageTests

struct TaskEventPageTests {
    @Test(arguments: ["all-kinds", "default-filter-delta-seqs", "gaps-skipped", "incomplete", "kinds-filtered",
                      "newer-empty-final", "newer", "newest", "older", "oldest-forward", "open", "settling", "unavailable"])
    func givenCanonicalPage_whenDecoded_thenRawFactsSurvive(name: String) throws {
        // given
        let raw = try #require(taskEventPageFixture(name)["result"]?.objectValue)
        // when
        let page = try #require(TaskEventPage(raw: raw, selection: eventSelection(raw)))
        // then
        #expect(page.raw == raw)
        #expect(page.events.map(\.raw) == raw["events"]?.arrayValue?.compactMap(\.objectValue))
        #expect(page.taskID == raw["task_id"]?.stringValue)
        #expect(page.olderCursor == raw["older_cursor"]?.stringValue)
        #expect(page.newerCursor == raw["newer_cursor"]?.stringValue)
        #expect(page.hasNewer == raw["has_newer"]?.boolValue)
        #expect(page.hasOlder == raw["has_older"]?.boolValue)
    }

    @Test(arguments: ["tool_result", "task_started", "assistant_text", "future_kind"])
    func givenNormalizedStub_whenDecoded_thenNoPayloadFactsAreFabricated(kind: String) throws {
        // given
        var record = eventRecordRaw()
        record.removeValue(forKey: "text")
        record["kind"] = .string(kind)
        record["truncated"] = .bool(true)
        record["oversized"] = .bool(true)
        record["bytes"] = .number(20000)
        record["future"] = .object(["loss": .string("unknown")])
        var raw = eventPageRaw()
        raw["events"] = .array([.object(record)])
        // when
        let page = try #require(TaskEventPage(raw: raw))
        let event = try #require(page.events.first)
        // then
        #expect(event.raw == record)
        #expect(event.raw["ok"] == nil)
        #expect(event.raw["text"] == nil)
        #expect(event.kind == kind)
        #expect(event.observedAt == nil)
    }

    @Test func givenRepeatedAndRegressingSequences_whenDecoded_thenProducerOrderAndSpanRemainIntact() throws {
        // given
        var raw = eventPageRaw()
        raw["events"] = .array([9, 9, 2].map { seq in
            var record = eventRecordRaw()
            record["seq"] = .number(Double(seq))
            return .object(record)
        })
        raw["span"] = .object(["first_seq": .number(9), "last_seq": .number(2)])
        raw["skipped"] = .object(["malformed": .number(1000), "oversized": .number(1000)])
        // when
        let page = try #require(TaskEventPage(raw: raw))
        // then
        #expect(page.events.map(\.seq) == [9, 9, 2])
        #expect(page.raw["span"] == raw["span"])
    }

    @Test func givenEmptyFilteredFinalPage_whenDecoded_thenCursorAndLossFactsRemainIndependent() throws {
        // given
        var raw = eventPageRaw()
        raw["events"] = .array([])
        raw["span"] = .object(["first_seq": .number(7), "last_seq": .number(90)])
        raw["log"] = .object(["state": .string("final"), "task_status": .string("completed"),
                              "output_drained": .bool(true), "capture_state": .string("future_capture"), "final_seq": .number(90)])
        raw["gaps"] = .array([.object(["after_seq": .number(7), "before_seq": .number(90), "reason": .string("future_reason")])])
        // when
        let page = try #require(TaskEventPage(raw: raw))
        // then
        #expect(page.events.isEmpty)
        #expect(page.newerCursor == "opaque/newer")
        #expect(page.raw == raw)
    }

    @Test func givenMalformedKnownPageFields_whenDecoded_thenTheyAreRejected() {
        // given
        let invalid: [(String, JSONValue)] = [
            ("task_id", .null), ("order", .string("descending")), ("kinds", .string("default")),
            ("events", .null), ("older_cursor", .number(1)), ("newer_cursor", .string("")),
            ("has_older", .number(0)), ("has_newer", .null), ("span", .bool(false)),
            ("skipped", .object(["malformed": .bool(true), "oversized": .number(0)])),
            ("skipped", .object(["malformed": .number(-1), "oversized": .number(0)])),
            ("gaps", .null), ("change_token", .null), ("observed_at", .number(1))
        ]
        // when / then
        for (key, value) in invalid {
            var raw = eventPageRaw()
            raw[key] = value
            #expect(TaskEventPage(raw: raw) == nil, "Invalid \(key): \(value)")
        }
        for key in eventPageRaw().keys {
            var raw = eventPageRaw()
            raw.removeValue(forKey: key)
            #expect(TaskEventPage(raw: raw) == nil, "Missing \(key)")
        }
    }

    @Test func givenMalformedNestedFields_whenDecoded_thenTheyAreRejected() {
        // given
        let cases: [(String, String, JSONValue)] = [
            ("log", "state", .string("future")), ("log", "output_drained", .number(1)),
            ("log", "capture_state", .null), ("log", "task_status", .bool(false)),
            ("log", "final_seq", .number(1, isInteger: false)), ("log", "final_seq", .number(-1)),
            ("span", "first_seq", .bool(true)), ("span", "last_seq", .number(-1)),
            ("skipped", "oversized", .number(1, isInteger: false))
        ]
        // when / then
        for (parent, key, value) in cases {
            var raw = eventPageRaw()
            var object = raw[parent]?.objectValue ?? [:]
            object[key] = value
            raw[parent] = .object(object)
            #expect(TaskEventPage(raw: raw) == nil, "Invalid \(parent).\(key)")
        }
        for key in ["product", "format", "product_version", "v", "seq", "kind", "observed_at"] {
            var raw = eventPageRaw()
            var record = eventRecordRaw()
            record.removeValue(forKey: key)
            raw["events"] = .array([.object(record)])
            #expect(TaskEventPage(raw: raw) == nil, "Missing record \(key)")
        }
    }

    @Test(arguments: [JSONValue.bool(true), .number(-1), .number(1, isInteger: false)])
    func givenInvalidSequence_whenDecoded_thenWireIntegerIsRequired(value: JSONValue) {
        // given
        var record = eventRecordRaw()
        record["seq"] = value
        var raw = eventPageRaw()
        raw["events"] = .array([.object(record)])
        // when / then
        #expect(TaskEventPage(raw: raw) == nil)
    }

    @Test func givenRowAndRecordBudgets_whenDecoded_thenProducerProfileBoundsApply() throws {
        // given
        var raw = eventPageRaw()
        var record = eventRecordRaw()
        record["text"] = .string(String(repeating: "🙂", count: 2000))
        raw["events"] = .array([.object(record)])
        // when / then
        #expect(TaskEventPage(raw: raw) != nil)
        raw["events"] = .array(Array(repeating: .object(eventRecordRaw()), count: 2))
        #expect(TaskEventPage(raw: raw, limit: 1) == nil)
        raw["events"] = .array([])
        raw["gaps"] = .array(Array(repeating: .object(["after_seq": .number(1), "before_seq": .number(3),
                                                     "reason": .string("missing")]), count: 2))
        #expect(TaskEventPage(raw: raw, limit: 1) == nil)
        raw["gaps"] = .array([])
        record["text"] = .string(String(repeating: "a", count: 17000))
        raw["events"] = .array([.object(record)])
        #expect(TaskEventPage(raw: raw) == nil)
    }

    @Test func givenMalformedRecordMetadata_whenDecoded_thenKnownTypesAreStrict() {
        // given
        let invalid: [(String, JSONValue)] = [
            ("observed_at", .bool(false)), ("truncated", .null), ("truncated", .number(1)),
            ("oversized", .string("true")), ("bytes", .bool(true)), ("bytes", .number(-1)),
            ("bytes", .number(1, isInteger: false)), ("v", .bool(true)), ("v", .number(1, isInteger: false)),
            ("product_version", .string("invalid")), ("kind", .null)
        ]
        // when / then
        for (key, value) in invalid {
            var raw = eventPageRaw()
            var record = eventRecordRaw()
            record[key] = value
            raw["events"] = .array([.object(record)])
            #expect(TaskEventPage(raw: raw) == nil, "Invalid record \(key)")
        }
        for parent in ["log", "span", "skipped"] {
            for key in eventPageRaw()[parent]?.objectValue?.keys.map(\.self) ?? [] {
                var raw = eventPageRaw()
                var object = raw[parent]?.objectValue ?? [:]
                object.removeValue(forKey: key)
                raw[parent] = .object(object)
                #expect(TaskEventPage(raw: raw) == nil, "Missing \(parent).\(key)")
            }
        }
    }

    @Test func givenSpanObject_whenEndpointIsNullOrMissing_thenItIsRejected() {
        // given
        let valid = eventPageRaw()
        // when / then
        for key in ["first_seq", "last_seq"] {
            for missing in [false, true] {
                var raw = valid
                var span = raw["span"]?.objectValue ?? [:]
                if missing {
                    span.removeValue(forKey: key)
                } else {
                    span[key] = .null
                }
                raw["span"] = .object(span)
                #expect(TaskEventPage(raw: raw) == nil, "Invalid span.\(key), missing=\(missing)")
            }
        }
        var raw = valid
        raw["span"] = .null
        #expect(TaskEventPage(raw: raw) == nil)
        raw["events"] = .array([])
        #expect(TaskEventPage(raw: raw) != nil)
        raw["gaps"] = .array([.object(["after_seq": .number(1), "before_seq": .number(3), "reason": .string("missing")])])
        #expect(TaskEventPage(raw: raw) == nil)
        raw["gaps"] = .array([])
        raw["span"] = .object(["first_seq": .number(1), "last_seq": .number(3)])
        #expect(TaskEventPage(raw: raw) != nil)
    }

}
