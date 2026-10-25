import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

private func actionRequest(tool: String, input: [String: JSONValue]) -> CallerApprovalRequest {
    CallerApprovalRequest(raw: [
        "request_id": .string("req-action"), "task_id": .string("task-action"),
        "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(1),
        "interaction_owner": .string("caller"), "disposition": .string("pending"), "delivery": .string("pending"),
        "complete": .bool(true), "action": .object(["tool_name": .string(tool), "input": .object(input)])
    ])
}

@Suite
struct CallerApprovalActionTests {
    @Test
    func givenBashAction_whenBuilt_thenCommandAndWorkingDirectoryAreLossless() {
        let action = CallerApprovalAction.build(actionRequest(tool: "Bash", input: [
            "command": .string("echo hello"), "cwd": .string("/workspace/repo")
        ]))
        #expect(action.title == "Run command")
        #expect(action.covered)
        #expect(action.fields.map(\.id) == ["tool", "input/command", "input/cwd"])
        #expect(action.fields.map(\.value) == ["Bash", "echo hello", "/workspace/repo"])
        #expect(action.fields.map(\.type) == ["Text", "Text", "Text"])
    }

    @Test
    func givenWriteAndEditActions_whenBuilt_thenContentAndReplacementFieldsRemainDistinct() {
        let write = CallerApprovalAction.build(actionRequest(tool: "Write", input: [
            "file_path": .string("/tmp/out.txt"), "content": .string("new contents")
        ]))
        #expect(write.title == "Write file")
        #expect(write.fields.map(\.label) == ["Tool", "Content", "Path"])

        let edit = CallerApprovalAction.build(actionRequest(tool: "Edit", input: [
            "file_path": .string("/tmp/out.txt"), "old_string": .string(""), "new_string": .string("replacement")
        ]))
        #expect(edit.title == "Edit file")
        #expect(edit.fields.first { $0.id == "input/old_string" }?.value == "")
        #expect(edit.fields.first { $0.id == "input/new_string" }?.value == "replacement")
        #expect(edit.fields.first { $0.id == "input/old_string" }?.type == "Empty text")
    }

    @Test
    func givenCodexFileChange_whenBuilt_thenRoutineCorrelationFieldsAreOmittedButPathsAndUnknownsRemain() {
        let action = CallerApprovalAction.build(actionRequest(tool: "filechange", input: [
            "threadId": .string("thread"), "turnId": .string("turn"), "itemId": .string("item"),
            "startedAtMs": .number(4), "path": .string("src/main.swift"), "kind": .string("edit"),
            "moveDestination": .string("src/new.swift"), "diff": .string("@@ -1 +1 @@"),
            "unknown": .object(["empty": .object([:]), "nested": .array([.null, .bool(true)])])
        ]))
        #expect(action.title == "Change files")
        let routineFields = ["threadId", "turnId", "itemId", "startedAtMs"]
        #expect(action.fields.allSatisfy { field in routineFields.allSatisfy { !field.id.contains($0) } })
        #expect(action.fields.contains { $0.id == "input/path" && $0.value == "src/main.swift" })
        #expect(action.fields.contains { $0.id == "input/unknown/empty" && $0.type == "Object" && $0.value == "Empty object" })
        #expect(action.fields.contains { $0.id == "input/unknown/nested/0" && $0.type == "Null" })
        #expect(action.fields.contains { $0.id == "input/unknown/nested/1" && $0.type == "Boolean" && $0.value == "true" })
    }

    @Test
    func givenMissingOrEmptyInput_whenBuilt_thenCoverageDisablesApprovalAndPreservesTypedEmptyValue() {
        let missing = actionRequest(tool: "Bash", input: [:])
        let action = CallerApprovalAction.build(missing)
        #expect(action.covered)
        #expect(action.fields == [
            .init(id: "tool", label: "Tool", value: "Bash", type: "Text"),
            .init(id: "input", label: "Input", value: "Empty object", type: "Object")
        ])

        var raw = missing.raw
        raw["action"] = .object(["tool_name": .string("Bash")])
        raw["complete"] = .bool(false)
        let unavailable = CallerApprovalAction.build(CallerApprovalRequest(raw: raw))
        #expect(unavailable.covered == false)
        #expect(unavailable.fields.isEmpty)
    }

    @Test
    func givenPointerLikeKeysAndLiteralEmptyText_whenBuilt_thenFieldIDsAndTypesRemainUnambiguous() {
        let action = CallerApprovalAction.build(actionRequest(tool: "Bash", input: [
            "a[0]": .string("literal"), "a": .array([.string("array")]),
            "slash/key": .string("slash"), "tilde~key": .string("tilde"), "dot.key": .string("dot"),
            "empty": .string(""), "literal": .string("Empty text")
        ]))
        let ids = action.fields.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.contains("input/a[0]"))
        #expect(ids.contains("input/a/0"))
        #expect(ids.contains("input/slash~1key"))
        #expect(ids.contains("input/tilde~0key"))
        #expect(ids.contains("input/dot.key"))
        #expect(action.fields.first { $0.id == "input/empty" }?.value == "")
        #expect(action.fields.first { $0.id == "input/empty" }?.type == "Empty text")
        #expect(action.fields.first { $0.id == "input/literal" }?.value == "Empty text")
        #expect(action.fields.first { $0.id == "input/literal" }?.type == "Text")
    }

    @Test
    func givenCodexReasonInput_whenBuilt_thenItUsesHumanLabelWithoutExposingRawPath() {
        let action = CallerApprovalAction.build(actionRequest(tool: "commandexecution", input: [
            "reason": .string("Needs repository context"), "threadId": .string("thread")
        ]))
        let reason = action.fields.first { $0.id == "input/reason" }
        #expect(reason?.label == "Agent's stated reason")
        #expect(reason?.value == "Needs repository context")
        #expect(action.fields.contains { $0.id == "input/threadId" } == false)
    }

    @Test
    func givenFutureCodexChangeKind_whenBuilt_thenChangeDetailsRemainVisibleButCoverageFailsClosed() {
        let action = CallerApprovalAction.build(actionRequest(tool: "filechange", input: [
            "changes": .array([.object([
                "kind": .object(["type": .string("future-kind")]),
                "path": .string("src/future.swift"), "diff": .string("@@ future")
            ])])
        ]))
        #expect(action.covered)
        #expect(action.knownEnums == false)
        #expect(action.fields.contains { $0.id == "input/changes/0/kind/type" && $0.value == "future-kind" })
        #expect(action.fields.contains { $0.id == "input/changes/0/path" && $0.value == "src/future.swift" })
        #expect(action.fields.contains { $0.id == "input/changes/0/diff" && $0.value == "@@ future" })
    }
}
