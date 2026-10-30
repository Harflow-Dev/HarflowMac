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

private final class CapabilityProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var probes = 0
    private let availableOnProbe: (Int) -> Bool

    init(availableOnProbe: @escaping (Int) -> Bool) {
        self.availableOnProbe = availableOnProbe
    }

    func isAvailable() -> Bool {
        lock.withLock {
            probes += 1
            return availableOnProbe(probes)
        }
    }
}

private func capabilityRunner(_ state: CapabilityProbeState,
                              answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
    RecordingRunner { call in
        if call.arguments == ["version-info", "--json"] {
            let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
            let capability = state.isAvailable() ? ",\"caller-approvals.monitor-respond.v1\"" : ""
            let document = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                "\"contracts\":{" +
                "\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                "\"setup\":{\"format\":\"harflow.setup\",\"v\":1}," +
                "\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"\(capability)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
            return ProcessOutput(exitCode: 0, stdout: json(document), stderr: "")
        }
        return answer(call)
    }
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
        let runner = compatibleRunner { call in
            switch call.arguments.first {
            case "approval-list":
                ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":2,"result":{"requests":[],"next_cursor":"16","total":17}}"#), stderr: "")
            case "approval-get", "approval-respond":
                ProcessOutput(exitCode: 0, stdout: ctlJSON(fixtureResponse), stderr: "")
            default: ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
            }
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        _ = await client.approvalList(taskID: "task-1", cursor: "16")
        let request = try await client.approvalGet(taskID: "task-1", requestID: "req-1").get()
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
        let runner = compatibleRunner { _ in ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":2,"result":{}}"#), stderr: "") }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        let result = await client.approvalRespond(CallerApprovalRequest(raw: raw), decision: "approve")
        guard case .failure = result else { Issue.record("incomplete or caller-owned request must be refused"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func givenUnknownApprovalOwnerOrState_whenPresented_thenItIsNeverActionable() async throws {
        var raw = approvalRaw(owner: "future-owner")
        raw["disposition"] = .string("future-state")
        let request = CallerApprovalRequest(raw: raw)
        #expect(request.interactionOwner == nil)
        #expect(request.isPending == false)
        #expect(request.mayBeAnsweredFromMonitor == false)

        let runner = compatibleRunner { _ in
            Issue.record("unknown approval state must not invoke ctl")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let result = await CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
            .approvalRespond(request, decision: "approve")
        guard case .failure = result else { Issue.record("unknown approval state should be refused"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func givenCallerOwnedRequest_whenCapabilityIsFresh_thenRespondUsesExactCapabilityGate() async throws {
        let state = CapabilityProbeState { _ in true }
        let response = ctlJSON(#"""
        {
            "v":2,"result":{"request_id":"req-1","task_id":"task-1",
            "action_digest":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "owner_revision":3,"interaction_owner":"caller","disposition":"decided",
            "delivery":"reserved","complete":true,"action":{"tool_name":"Bash",
            "input":{"command":"python3 -c exact"}}}
        }
        """#)
        let runner = capabilityRunner(state) { call in
            #expect(call.arguments.first == "approval-respond")
            return ProcessOutput(exitCode: 0, stdout: response, stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        let request = CallerApprovalRequest(raw: approvalRaw(owner: "caller"))
        let result = await client.approvalRespond(request, decision: "approve")
        guard case .success = result else { Issue.record("caller-owned response should succeed with capability"); return }
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments.contains("--monitor"))
        #expect(runner.calls[0].arguments.contains("--action-digest=\(request.digest)"))
        #expect(runner.calls[0].arguments.contains("--owner-revision=3"))
        #expect(runner.calls[0].arguments.contains("--decision=approve"))
    }

    @Test
    func givenCallerOwnedCard_whenCapabilityDisappearsBeforeResponse_thenCtlMutationIsNotSent() async throws {
        let state = CapabilityProbeState { $0 == 1 }
        let runner = capabilityRunner(state) { _ in
            Issue.record("capability loss must prevent approval-respond")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected mutation")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        #expect(try await client.supportsMonitorResponseForCallerApprovals().get() == true)
        let result = await client.approvalRespond(CallerApprovalRequest(raw: approvalRaw(owner: "caller")), decision: "approve")
        guard case .failure(let error) = result else { Issue.record("missing capability must fail closed"); return }
        guard case .unsupportedCommand = error else { Issue.record("missing capability should be an unsupported command"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test
    func givenApprovalRefusalEnvelope_whenDecoded_thenTypedLegacyAndUnknownReasonsRemainDistinct() {
        let typed = ToolError.structuredRefusal(code: "approval_error", message: "expired", data: ["reason": .string("expired")])
        #expect(typed.callerApprovalResponseReason == .expired)
        let legacy = ToolError.refused(code: "approval_error", message: "already answered")
        #expect(legacy.callerApprovalResponseReason == nil)
        let unknown = ToolError.structuredRefusal(code: "approval_error", message: "future", data: ["reason": .string("future_reason")])
        #expect(unknown.callerApprovalResponseReason == nil)
        let undecidable = ToolError.refused(code: "caller_undecidable", message: "lineage unavailable")
        #expect(undecidable.callerApprovalResponseReason == .callerUndecidable)
    }
}

// MARK: - CallerApprovalRequest eligibility

struct CallerApprovalEligibilityTests {
    private func request(
        action: JSONValue? = .object(["tool_name": .string("Bash"), "input": .object(["command": .string("ls")])]),
        owner: String = "monitor", deadline: Double = 4_000_000_000
    ) -> CallerApprovalRequest {
        var raw: [String: JSONValue] = [
            "request_id": .string("r"), "task_id": .string("t"), "action_digest": .string("d"), "interaction_owner": .string(owner),
            "owner_revision": .number(1), "generation": .string("g"), "disposition": .string("pending"), "delivery": .string("pending"),
            "execution_outcome": .string("unknown"), "complete": .bool(true), "deadline": .number(deadline)
        ]
        raw["action"] = action
        return CallerApprovalRequest(raw: raw)
    }

    private let now = Date(timeIntervalSince1970: 1_000_000)

    @Test func givenCompleteMonitorOwnedRequest_whenChecked_thenEligible() {
        #expect(request().isEligibleForMonitorResponse(supportsCallerResponses: false, now: now))
    }

    @Test func givenCallerOwnedRequest_whenCapabilityIsMissing_thenIneligible() {
        #expect(!request(owner: "caller").isEligibleForMonitorResponse(supportsCallerResponses: false, now: now))
        #expect(request(owner: "caller").isEligibleForMonitorResponse(supportsCallerResponses: true, now: now))
    }

    @Test func givenUncoveredAction_whenChecked_thenIneligible() {
        let value = request(action: .object(["tool_name": .string("Bash")]))
        #expect(!value.hasCoveredAction && !value.isEligibleForMonitorResponse(supportsCallerResponses: true, now: now))
    }

    @Test func givenUnknownFileChangeKind_whenChecked_thenIneligible() {
        let changes = JSONValue.array([.object(["kind": .object(["type": .string("teleport")])])])
        let value = request(action: .object(["tool_name": .string("fileChange"), "input": .object(["changes": changes])]))
        #expect(!value.hasKnownActionEnums && !value.isEligibleForMonitorResponse(supportsCallerResponses: true, now: now))
    }

    @Test func givenPastDeadline_whenChecked_thenIneligible() {
        #expect(!request(deadline: 10).isEligibleForMonitorResponse(supportsCallerResponses: true, now: now))
    }
}
