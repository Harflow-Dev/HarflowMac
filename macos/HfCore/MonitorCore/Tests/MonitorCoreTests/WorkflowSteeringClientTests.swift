import Foundation
@testable import MonitorCore
import Testing

struct WorkflowSteeringClientTests {
    private let root = String(repeating: "a", count: 32)
    private let episodeID = String(repeating: "c", count: 32)

    @Test func givenSteeringCapabilities_whenSendingRequest_thenUsesPrivateRequestFileAndExactMonitorArguments() async throws {
        let request = try makeRequest()
        let runner = steeringRunner { call in
            guard let option = call.arguments.first(where: { $0.hasPrefix("--request-file=") }) else {
                Issue.record("Expected a private request file argument")
                return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "missing request file")
            }
            let path = String(option.dropFirst("--request-file=".count))
            #expect((try? Data(contentsOf: URL(fileURLWithPath: path))) == request.data)
            #expect((try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            #expect((try? FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int) == 0o700)
            let result: [String: Any] = ["accepted": true, "request_id": request.requestID, "episode_id": episodeID,
                "steering_revision": 1, "interaction_epoch": request.status.interactionEpoch,
                "control_revision": request.status.controlRevision, "ledger_epoch": request.status.ledgerEpoch!,
                "sequence": request.status.sequence + 1, "scheduled": false, "replayed": false, "state": "pending"]
            return ProcessOutput(exitCode: 0, stdout: (try? envelope(result)) ?? Data(), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)

        let outcome = await client.workflowSteer(request)

        guard case .admitted = outcome else { Issue.record("Expected a matching positive receipt"); return }
        let call = try #require(runner.calls.first)
        #expect(call.arguments.first == "workflow-steer")
        #expect(call.arguments.contains("--monitor"))
        #expect(call.arguments.contains("--json"))
        #expect(call.arguments.last == root)
        #expect(call.arguments.contains { $0.hasPrefix("--request-file=") })
        let requestPath = try #require(call.arguments.first(where: { $0.hasPrefix("--request-file=") })).dropFirst("--request-file=".count)
        #expect(!FileManager.default.fileExists(atPath: String(requestPath)))
        let requestDirectory = URL(fileURLWithPath: String(requestPath)).deletingLastPathComponent()
        #expect(!FileManager.default.fileExists(atPath: requestDirectory.path))
    }

    @Test func givenCapabilitiesMissing_whenReadingSteeringStatus_thenDoesNotDispatchOperation() async {
        let runner = runner(capabilities: ["ctl.v1", "setup.v1", "events.v1", "messaging.v1"]) { _ in
            Issue.record("Operation should not run without both steering capabilities")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        let result = await client.workflowSteeringStatus(rootID: root)
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.count == 1)
        if case .success = result { Issue.record("Expected capability refusal") }
    }

    @Test(arguments: ["interaction_revoked", "steering_revision_stale", "steering_target_stale", "request_expired", "steering_budget_exhausted"])
    func givenAuditedProducerAndDefinitePreAdmissionCode_whenSending_thenClassifiesAsRefused(code: String) async throws {
        let request = try makeRequest()
        let client = try auditedClient(output: structuredError(code: code, exitCode: 2))

        let outcome = await client.workflowSteer(request)

        guard case let .refused(failure) = outcome else { Issue.record("Expected an audited preadmission refusal"); return }
        #expect(failure.structuredCode == code)
        #expect(failure.definiteExit)
        #expect(failure.auditedProducer)
    }

    @Test(arguments: ["steering_queue_full", "steering_source_unavailable", "steering_busy", "workflow_error"])
    func givenPostAdmissionCapableCode_whenSending_thenRemainsIndeterminate(code: String) async throws {
        let request = try makeRequest()
        let client = try auditedClient(output: structuredError(code: code, exitCode: 2))
        let outcome = await client.workflowSteer(request)
        guard case let .indeterminate(failure) = outcome else { Issue.record("Expected an indeterminate command result"); return }
        switch failure.error {
        case let .refused(parsedCode, _), let .structuredRefusal(parsedCode, _, _):
            #expect(parsedCode == code)
        default:
            Issue.record("Expected the validated structured refusal code to remain typed")
        }
    }

    @Test func givenPreadmissionCodeWithReceiptReferenceOrUnqualifiedProducer_whenSending_thenRemainsIndeterminate() async throws {
        let request = try makeRequest()
        let withReference = try auditedClient(output: structuredError(code: "interaction_revoked", exitCode: 2, receiptReference: "receipt"))
        let unqualified = try auditedClient(output: structuredError(code: "interaction_revoked", exitCode: 2), qualified: false)

        for client in [withReference, unqualified] {
            let outcome = await client.workflowSteer(request)
            guard case .indeterminate = outcome else { Issue.record("Expected the refusal to remain indeterminate"); continue }
        }
    }

    @Test func givenTimedOutOrMissingPositiveExitEvidence_whenSending_thenRemainsIndeterminate() async throws {
        let request = try makeRequest()
        let timeout = try auditedClient(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "timed out", timedOut: true))
        let noPositiveExit = try auditedClient(output: structuredError(code: "interaction_revoked", exitCode: 0))

        for client in [timeout, noPositiveExit] {
            let outcome = await client.workflowSteer(request)
            guard case .indeterminate = outcome else { Issue.record("Expected missing exit evidence to remain indeterminate"); continue }
        }
    }

    private func makeRequest() throws -> WorkflowSteeringRequest {
        let target: [String: Any] = ["root_workflow_run_id": root, "workflow_run_id": root, "path": [root], "role": "orchestrator",
            "checkpoint_revision": 1, "goal_revision": 2, "interaction_epoch": 3, "control_revision": 4,
            "assignment_revision": NSNull(), "draft_revision": NSNull(), "source_revision": NSNull(), "activation_id": NSNull(),
            "assignment_digest": NSNull(), "decision_id": NSNull(), "definition_digest": NSNull(), "node_id": NSNull(),
            "preview_hash": NSNull(), "source_definition_digest": NSNull(), "source_workflow_id": NSNull(), "task_id": NSNull(), "token_id": NSNull()]
        let result: [String: Any] = ["root_workflow_run_id": root, "steering_version": 1, "request_schema_version": 2,
            "ledger_epoch": 5, "interaction_epoch": 3, "control_revision": 4, "sequence": 10, "owner": "monitor",
            "eligible_actions": ["open"], "targets": [target], "episodes": []]
        let status = try #require(WorkflowSteeringStatus(data: try envelope(result), rootID: root))
        return try WorkflowSteeringRequest(status: status, action: .open, text: "test",
                                           requestID: UUID(uuidString: "0f8a560b-19e5-4e11-afb5-9edcb44c9d13")!)
    }

    private func steeringRunner(answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
        runner(capabilities: ["ctl.v1", "setup.v1", "events.v1", "messaging.v1", "workflow-steering-read.v1",
                              "workflow-steering-orchestrator.v1"], answer: answer)
    }

    private func runner(capabilities: [String], answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
        RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let stateRoot = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                let object: [String: Any] = ["product": "harflow", "format": "harflow.version-info", "v": 1,
                    "product_version": HarflowVersion.current, "component": "engine", "state_root": stateRoot,
                    "contracts": ["ctl": ["format": "harflow.ctl", "v": 1], "setup": ["format": "harflow.setup", "v": 1],
                                  "events": ["format": "harflow.event", "v": 1]], "capabilities": capabilities,
                    "os": "darwin", "architecture": "arm64"]
                return ProcessOutput(exitCode: 0, stdout: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), stderr: "")
            }
            return answer(call)
        }
    }

    private func envelope(_ result: [String: Any]) throws -> Data {
        let object: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                     "product_version": HarflowVersion.current, "result": result]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private func auditedClient(output: ProcessOutput, qualified: Bool = true) throws -> CtlClient {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("steering-runtime-\(UUID().uuidString)")
        let environment = ["HOME": home.path]
        let stateRoot = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
        let executable: String
        if qualified {
            let specification = try ManagedRuntimeSpecification.bundled()
            let layout = ManagedRuntimeLayout(home: home.path)
            let generation = UUID().uuidString.lowercased()
            executable = layout.generationsDirectory + "/0.0.14-\(specification.identity)-\(generation)/bin/harflow-ctl"
        } else {
            executable = "/fixture/ctl"
        }
        let runner = RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let version: [String: Any] = ["product": "harflow", "format": "harflow.version-info", "v": 1,
                    "product_version": "0.0.14", "component": "engine", "state_root": stateRoot,
                    "contracts": ["ctl": ["format": "harflow.ctl", "v": 1], "setup": ["format": "harflow.setup", "v": 1],
                                  "events": ["format": "harflow.event", "v": 1]],
                    "capabilities": ["ctl.v1", "setup.v1", "events.v1", "workflow-steering-read.v1", "workflow-steering-orchestrator.v1"],
                    "os": "darwin", "architecture": "arm64"]
                return ProcessOutput(exitCode: 0, stdout: (try? JSONSerialization.data(withJSONObject: version)) ?? Data(), stderr: "")
            }
            return output
        }
        return CtlClient(executable: executable, environment: environment, runner: runner)
    }

    private func structuredError(code: String, exitCode: Int32, receiptReference: String? = nil) -> ProcessOutput {
        var detail: [String: Any] = [:]
        if let receiptReference { detail["receipt_ref"] = receiptReference }
        let error: [String: Any] = ["code": code, "message": "fixture error", "data": detail]
        let object: [String: Any] = ["product": "harflow", "format": "harflow.ctl", "v": 1,
                                     "product_version": "0.0.14", "error": error]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return ProcessOutput(exitCode: exitCode, stdout: data, stderr: "fixture error")
    }
}
