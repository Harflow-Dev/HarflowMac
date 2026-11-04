import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskPromptTests

struct TaskPromptTests {
    @Test(arguments: ["available", "truncated", "preview-only", "integrity-failed"])
    func givenCanonicalPrompt_whenDecoded_thenEveryWireFactSurvives(name: String) throws {
        // given
        let url = try #require(Bundle.module.url(forResource: "ctl-task-prompt-\(name)", withExtension: "json", subdirectory: "ContractsV1"))
        let raw = try #require(JSONValue.parse(Data(contentsOf: url))?.objectValue?["result"]?.objectValue)
        let prompt = try #require(raw["prompt"]?.objectValue)
        // when
        let value = try #require(TaskPromptResult(raw: raw))
        // then
        #expect(value.raw == raw)
        #expect(value.taskID == raw["task_id"]?.stringValue)
        #expect(value.title == raw["title"]?.stringValue)
        #expect(value.text == prompt["text"]?.stringValue)
        #expect(value.returnedBytes == prompt["returned_bytes"]?.wireIntegerValue)
        #expect(value.totalBytes == prompt["total_bytes"]?.wireIntegerValue)
        #expect(value.complete == prompt["complete"]?.boolValue)
        #expect(value.truncated == prompt["truncated"]?.boolValue)
    }

    @Test(arguments: ["", " \n\t café🙂\n", "�"])
    func givenExactText_whenDecoded_thenUTF8AndWhitespaceArePreserved(text: String) throws {
        // given
        let raw = promptRaw(text: text)
        // when
        let value = try #require(TaskPromptResult(raw: raw, maxBytes: max(1, text.utf8.count)))
        // then
        #expect(value.text == text)
        #expect(value.returnedBytes == text.utf8.count)
        if !text.isEmpty { #expect(TaskPromptResult(raw: raw, maxBytes: text.utf8.count - 1) == nil) }
    }

    @Test func givenEscapedMaximumText_whenDecoded_thenJSONDocumentSizeDoesNotLimitPromptBytes() throws {
        // given
        let text = String(repeating: "\u{0001}", count: 131072)
        let raw = promptRaw(text: text)
        #expect(JSONValue.object(raw).rendered().utf8.count > 262144)
        // when / then
        #expect(try #require(TaskPromptResult(raw: raw, maxBytes: 131072)).text == text)
        #expect(TaskPromptResult(raw: raw) == nil)
    }

    @Test func givenUnverifiedAndIndependentCompleteness_whenDecoded_thenProducerFactsRemainIndependent() throws {
        // given
        var raw = promptRaw(text: "prefix", integrity: "unverified", complete: false)
        var prompt = try #require(raw["prompt"]?.objectValue)
        prompt["total_bytes"] = .number(1)
        raw["prompt"] = .object(prompt)
        // when / then
        #expect(try #require(TaskPromptResult(raw: raw)).integrity == .unverified)
        #expect(TaskPromptResult(raw: promptRaw(text: "prefix", complete: false)) != nil)
        #expect(TaskPromptResult(raw: promptRaw(text: "prefix", complete: false, truncated: true)) != nil)
    }

    @Test(arguments: ["unavailable", "integrity_failed"])
    func givenExplicitAbsentText_whenDecoded_thenStateIsNotEmptyAvailable(state: String) throws {
        // given
        let raw = promptRaw(text: nil, state: state, integrity: state == "integrity_failed" ? "failed" : "not_applicable", complete: false)
        // when
        let value = try #require(TaskPromptResult(raw: raw))
        // then
        #expect(value.text == nil)
        #expect(value.state == (state == "unavailable" ? .unavailable : .integrityFailed))
    }

    @Test func givenMalformedKnownFields_whenDecoded_thenTheyAreRejected() throws {
        // given
        let valid = promptRaw(text: "abc")
        let invalid: [(String, JSONValue)] = [
            ("state", .string("future")), ("integrity", .string("future")),
            ("returned_bytes", .bool(true)), ("returned_bytes", .number(3, isInteger: false)),
            ("returned_bytes", .number(-1)), ("returned_bytes", .number(2)),
            ("total_bytes", .bool(false)), ("total_bytes", .number(-1)), ("total_bytes", .number(4)),
            ("complete", .number(1)), ("truncated", .string("false")),
            ("text", .null), ("text", .number(3)), ("state", .string("integrity_failed"))
        ]
        // when / then
        for (key, value) in invalid {
            var raw = valid
            var prompt = try #require(raw["prompt"]?.objectValue)
            prompt[key] = value
            raw["prompt"] = .object(prompt)
            #expect(TaskPromptResult(raw: raw) == nil, "Invalid \(key): \(value)")
        }
        for key in ["state", "text", "returned_bytes", "total_bytes", "complete", "truncated", "integrity"] {
            var raw = valid
            var prompt = try #require(raw["prompt"]?.objectValue)
            prompt.removeValue(forKey: key)
            raw["prompt"] = .object(prompt)
            #expect(TaskPromptResult(raw: raw) == nil, "Missing \(key)")
        }
        for key in ["task_id", "title", "prompt"] {
            var raw = valid
            raw.removeValue(forKey: key)
            #expect(TaskPromptResult(raw: raw) == nil)
        }
    }

    @Test func givenAdditiveFields_whenDecoded_thenRawPayloadRetainsThem() throws {
        // given
        var raw = promptRaw(text: "abc")
        raw["future"] = .object(["evidence": .bool(true)])
        // when / then
        #expect(try #require(TaskPromptResult(raw: raw)).raw == raw)
    }
}

func promptRaw(taskID: String = "task", text: String?, state: String = "available", integrity: String = "verified",
               complete: Bool = true, truncated: Bool = false) -> [String: JSONValue] {
    ["task_id": .string(taskID), "title": .string("Review"), "prompt": .object([
        "state": .string(state), "text": text.map(JSONValue.string) ?? .null,
        "returned_bytes": .number(Double(text?.utf8.count ?? 0)),
        "total_bytes": text.map { .number(Double($0.utf8.count)) } ?? .null,
        "complete": .bool(complete), "truncated": .bool(truncated), "integrity": .string(integrity)
    ])]
}
