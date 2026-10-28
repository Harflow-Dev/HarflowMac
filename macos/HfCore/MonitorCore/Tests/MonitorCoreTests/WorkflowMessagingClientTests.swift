import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowMessagingClientTests

struct WorkflowMessagingClientTests {
    @Test func givenMessagingCapableEngine_whenBuildingAsMonitor_thenOwnershipFlagReachesCtl() async throws {
        // given
        let runner = compatibleRunner { _ in
            ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":2,"result":{"workflow_run_id":"builder"}}"#), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        _ = try await client.workflow("build", options: ["--monitor", "--prompt=exact text"], positionals: ["draft"]).get()
        // then
        #expect(runner.calls.map(\.arguments) == [["workflow-build", "--monitor", "--prompt=exact text", "--json", "--", "draft"]])
    }

    @Test func givenLegacyEngine_whenBuildingAsMonitor_thenCapabilityRefusalPreventsMutation() async throws {
        // given
        let runner = RecordingRunner { call in
            let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
            let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.version-info"),
                "v": .number(1), "product_version": .string(HarflowVersion.current), "component": .string("engine"),
                "state_root": .string(root), "os": .string("darwin"), "architecture": .string("arm64"),
                "contracts": .object([
                    "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                    "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                    "events": .object(["format": .string("harflow.event"), "v": .number(1)])]),
                "capabilities": .array([.string("ctl.v1"), .string("setup.v1"), .string("events.v1")])]
            return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("build", options: ["--monitor", "--prompt=exact text"], positionals: ["draft"])
        // then
        guard case let .failure(error) = result else { Issue.record("Expected a missing-capability refusal"); return }
        #expect(error.message.contains("messaging.v1"))
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test func givenExactMissingMessagingCapability_whenExplaining_thenNamesCapabilityWithoutClaimingCommandMissing() {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: "Missing capability messaging.v1")
        // when / then
        #expect(error.message == "The installed `harflow-ctl` does not support capability `messaging.v1`, required for `send`. "
            + "Use a compatible managed Harflow runtime.")
    }

    @Test(arguments: ["invalid choice", "Missing capability unknown.v1", "Missing capability messaging.v1\nopaque provider output"])
    func givenOtherUnsupportedDetail_whenExplaining_thenRetainsExistingBoundedCommandGuidance(detail: String) {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "send", detail: detail)
        // when / then
        #expect(error.message == "The installed `harflow-ctl` has no `send` command — it predates this app. "
            + "Use a compatible managed Harflow runtime.")
    }

}
