import Foundation
@testable import MonitorCore
import Testing

struct QualificationClientTests {
    private func runner(supported: Bool = true, exitCode: Int32 = 0, result: String) -> RecordingRunner {
        let compatible = compatibleRunner { _ in
            ProcessOutput(exitCode: exitCode, stdout: ctlJSON("{\"v\":1,\"result\":\(result)}"), stderr: "fixture diagnostic")
        }
        return RecordingRunner { call in
            let output = compatible.answer(call)
            guard supported, call.arguments == ["version-info", "--json"],
                  let document = String(data: output.stdout, encoding: .utf8) else { return output }
            let text = document.replacingOccurrences(of: "\"ctl.v1\"", with: "\"ctl.v1\",\"backend-qualification.v1\"")
            return ProcessOutput(exitCode: 0, stdout: Data(text.utf8), stderr: "")
        }
    }

    @Test func givenFailedExplicitQualification_whenExitOne_thenKeepFeatureEvidenceAndExactFeatures() async throws {
        // given
        let response = "{\"backend\":\"codex\",\"ok\":false,\"features\":{" +
            "\"write\":{\"ok\":false,\"source\":\"failed\"}," +
            "\"approval\":{\"ok\":false,\"source\":\"failed\"}}}"
        let runner = runner(exitCode: 1, result: response)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.qualify(backend: "codex", features: ["write", "approval"])
        // then
        #expect(try result.get()["ok"]?.boolValue == false)
        #expect(runner.calls.map(\.arguments) == [["qualify", "--feature=write", "--feature=approval", "--json", "--", "codex"]])
    }

    @Test func givenOldEngine_whenReadingPlan_thenUnsupportedWithoutPreviewOrProbe() async {
        // given
        let runner = runner(supported: false, result: "{}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.taskQualificationPlan(options: ["--backend=codex"])
        // then
        guard case .failure(.unsupportedCommand) = result else { Issue.record("Expected unsupported capability"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenDiscoveryRead_whenSupported_thenQualificationOnlyBeforePermissionNegotiation() async throws {
        // given
        let runner = runner(result: "{\"qualification_version\":1,\"discovery_only\":true,\"requirements\":[]}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        _ = try await client.workflowQualificationPlan(name: "-fixture", options: ["--repo=/fixture"]).get()
        // then
        #expect(runner.calls.map(\.arguments) == [["workflow-preview", "--repo=/fixture", "--qualification-only", "--json", "--", "-fixture"]])
    }

    @Test func givenOldEngine_whenExplicitlyChecking_thenNoQualificationLaunch() async {
        // given
        let runner = runner(supported: false, result: "{}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.qualify(backend: "codex", features: ["write"])
        // then
        guard case .failure(.unsupportedCommand) = result else { Issue.record("Expected unsupported capability"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenMalformedFailedFeature_whenChecking_thenFailClosed() async {
        // given
        let runner = runner(exitCode: 1, result: "{\"backend\":\"codex\",\"ok\":false,\"features\":{\"write\":{\"ok\":true}}}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.qualify(backend: "codex", features: ["write"])
        // then
        guard case .failure = result else { Issue.record("Malformed evidence must fail closed"); return }
    }

    @Test func givenUnavailableHarness_whenSettingsInspects_thenReasonWithoutInventedFeatureRows() async throws {
        // given
        let base = runner(result: "{}")
        let runner = RecordingRunner { call in
            if call.arguments.first != "backends" { return base.answer(call) }
            let body = "{\"v\":1,\"backends\":[{\"backend\":\"fixture\",\"qualification\":{" +
                "\"features\":{},\"unavailable_reason\":\"Fixture binary missing\"}}]}"
            return ProcessOutput(exitCode: 0, stdout: ctlJSON(body), stderr: "")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let plan = try await client.harnessQualificationPlan(backend: "fixture").get()
        // then
        #expect(!plan.isReady)
        #expect(plan.requirements.first?.features.isEmpty == true)
        #expect(plan.requirements.first?.unavailableReason == "Fixture binary missing")
        #expect(runner.calls.map(\.arguments) == [["backends", "--json"]])
    }

    @Test func givenOlderEngine_whenSettingsInspects_thenUnsupportedWithoutBackendRead() async {
        // given
        let runner = runner(supported: false, result: "{}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.harnessQualificationPlan(backend: "fixture")
        // then
        guard case .failure(.unsupportedCommand) = result else { Issue.record("Expected unsupported capability"); return }
        #expect(runner.calls.isEmpty)
    }

}
