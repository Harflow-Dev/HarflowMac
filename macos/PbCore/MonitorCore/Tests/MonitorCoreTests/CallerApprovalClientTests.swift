import Foundation
@testable import MonitorCore
import Testing

private func approvalRaw(complete: Bool = true, owner: String = "monitor", revision: Int = 3) -> [String: JSONValue] {
    var raw: [String: JSONValue] = [
        "request_id": .string("req-1"), "task_id": .string("task-1"),
        "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(Double(revision)),
        "interaction_owner": .string(owner), "disposition": .string("pending"), "delivery": .string("pending"),
        "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970)
    ]
    if complete {
        raw["complete"] = .bool(true)
        raw["action"] = .object(["tool_name": .string("Bash"), "input": .object(["command": .string("python3 -c exact")])])
    }
    return raw
}

@Suite(.serialized)
struct CallerApprovalClientTests {
    @Test
    func givenApprovalCommands_whenRequested_thenOptionsAndPositionalsRemainExact() async throws {
        let fixtureResponse = """
        {"v":2,"result":{"request_id":"req-1","task_id":"task-1",
        "action_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        "owner_revision":3,"interaction_owner":"monitor","disposition":"pending",
        "delivery":"pending","complete":true,"action":{"tool_name":"Bash",
        "input":{"command":"python3 -c exact"}}}}
        """
        let runner = RecordingRunner { call in
            switch call.arguments.first {
            case "approval-list":
                ProcessOutput(exitCode: 0, stdout: json(#"{"v":2,"result":{"requests":[],"next_cursor":"16","total":17}}"#), stderr: "")
            case "approval-get", "approval-respond":
                ProcessOutput(exitCode: 0, stdout: json(fixtureResponse), stderr: "")
            default: ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
            }
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        _ = await client.approvalList(taskID: "task-1", cursor: "16")
        let request = try #require(await client.approvalGet(taskID: "task-1", requestID: "req-1").get())
        _ = await client.approvalRespond(request, decision: "approve")
        #expect(runner.calls[0].arguments == ["approval-list", "--limit=16", "--task-id=task-1", "--cursor=16", "--json"])
        #expect(runner.calls[1].arguments == ["approval-get", "--monitor", "--json", "--", "task-1", "req-1"])
        #expect(runner.calls[2].arguments.contains("--action-digest=\(request.digest)"))
        #expect(runner.calls[2].arguments.contains("--owner-revision=3"))
        #expect(runner.calls[2].arguments.contains("--decision=approve"))
    }

    @Test
    func givenIncompleteRequest_whenResponding_thenNoCtlMutationIsSent() async throws {
        let raw = approvalRaw(complete: false)
        let runner = RecordingRunner { _ in ProcessOutput(exitCode: 0, stdout: json(#"{"v":2,"result":{}}"#), stderr: "") }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        let result = await client.approvalRespond(CallerApprovalRequest(raw: raw), decision: "approve")
        guard case .failure = result else { Issue.record("incomplete or caller-owned request must be refused"); return }
        #expect(runner.calls.isEmpty)
    }
}
