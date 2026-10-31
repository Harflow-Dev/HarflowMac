import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowAttentionCheckpointClientTests

@Suite(.serialized) struct WorkflowAttentionCheckpointClientTests {
    private func runner(capable: Bool, answer: @escaping @Sendable (RecordingRunner.Call) -> ProcessOutput) -> RecordingRunner {
        RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                let guarded = capable ? ",\"workflow-attention-checkpoints.v1\"" : ""
                let raw = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                    "\"product_version\":\"\(HarflowVersion.current)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"\(guarded)],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                return ProcessOutput(exitCode: 0, stdout: json(raw), stderr: "")
            }
            return answer(call)
        }
    }

    @Test func givenGuardedRecovery_whenTransported_thenFreshCapabilityAndOpaqueTokenReachCtl() async throws {
        // given
        let token = "attention:root:opaque-checkpoint"
        let runner = runner(capable: true) { _ in ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":2,"result":{}}"#), stderr: "") }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow(
            "resume",
            options: ["--monitor", "--attention-checkpoint-id=\(token)", "--instructions=keep draft"],
            positionals: ["root"]
        )
        // then
        guard case .success = result else { Issue.record("qualified recovery should be sent"); return }
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"],
                                                     ["workflow-resume", "--monitor", "--attention-checkpoint-id=\(token)",
                                                      "--instructions=keep draft", "--json", "--", "root"]])
    }

    @Test func givenLegacyEngine_whenGuardedRecoveryRequested_thenOperationIsNeverLaunched() async {
        // given
        let runner = runner(capable: false) { _ in
            Issue.record("the guarded operation must not launch without the fresh capability")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("recover", options: ["--monitor", "--attention-checkpoint-id=scheduler:root:opaque"], positionals: ["root"])
        // then
        guard case let .failure(error) = result else { Issue.record("missing capability should refuse recovery"); return }
        #expect(error.message.contains("cannot safely continue this workflow checkpoint"))
        #expect(runner.calls.isEmpty)
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test func givenDecisionQuestion_whenResumed_thenLegacyDecisionPathNeedsNoCheckpointCapability() async throws {
        // given
        let runner = runner(capable: false) { _ in ProcessOutput(exitCode: 0, stdout: ctlJSON(#"{"v":2,"result":{}}"#), stderr: "") }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("resume", options: ["--monitor", "--decision-id=d1", "--instructions=answer"], positionals: ["root"])
        // then
        guard case .success = result else { Issue.record("decision-id questions retain their existing path"); return }
        #expect(runner.calls.map(\.arguments) == [["workflow-resume", "--monitor", "--decision-id=d1", "--instructions=answer", "--json", "--", "root"]])
    }

    @Test func givenQuestionAndCheckpointTogether_whenRequested_thenRefusesBeforeAnyProcessCall() async {
        // given
        let runner = runner(capable: true) { _ in
            Issue.record("conflicting question and attention identity must not invoke ctl")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("resume", options: ["--decision-id=d1", "--attention-checkpoint-id=attention:r:x"], positionals: ["root"])
        // then
        guard case let .failure(error) = result else { Issue.record("incompatible identities should be refused"); return }
        #expect(error.refusalCode == "attention_checkpoint_invalid")
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: [["--decision-id=d1"], ["--decision-id", "d1"]])
    func givenDecisionIdentityOnRecover_whenRequested_thenRefusesBeforeCapabilityOrProcessCall(_ decisionOptions: [String]) async {
        // given
        let runner = runner(capable: true) { _ in
            Issue.record("recover with a decision identity must not invoke ctl")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: [:], runner: runner)

        // when
        let result = await client.workflow("recover", options: ["--monitor"] + decisionOptions, positionals: ["root"])

        // then
        guard case let .failure(error) = result else { Issue.record("recover cannot use question identity"); return }
        #expect(error.refusalCode == "attention_checkpoint_invalid")
        #expect(runner.allCalls.isEmpty)
    }
}
