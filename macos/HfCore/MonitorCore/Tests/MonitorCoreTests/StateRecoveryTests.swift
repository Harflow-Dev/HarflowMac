import Foundation
@testable import MonitorCore
import Testing

// swiftlint:disable line_length

@Suite
struct StateRecoveryTests {
    private let operation = String(repeating: "a", count: 32)

    private func proposal() -> String {
        #"{"operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","confirmation_token":"opaque","backup_path":"/tmp/harflow-fixture-home/.harflow-backup-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phase":"proposed","resumable":false}"#
    }

    private func inspection(
        reason: String = "future_reason", recoverySupported: Bool = true, recovery: String? = nil
    ) -> [String: JSONValue] {
        var value: [String: JSONValue] = [
            "state_root": .string("/tmp/harflow-fixture-home/.harflow"),
            "engine_version": .string("0.0.2"), "status": .string("incompatible"),
            "reason": .string(reason), "message": .string("store refused"),
            "recovery_supported": .bool(recoverySupported), "cooperative_ownership_only": .bool(true)
        ]
        if let recovery, let object = JSONValue.parse(Data(recovery.utf8)) { value["recovery"] = object }
        return value
    }

    @Test
    func givenUnknownReason_whenDecodingInspection_thenRawValueIsPreserved() {
        let value = inspection(recovery: proposal())
        let decoded = StateInspection(value)
        #expect(decoded?.reason.rawValue == "future_reason")
        #expect(decoded?.recovery?.operationID == operation)
    }

    @Test
    func givenReadyOrMissingRecoverySupport_whenProposalPresent_thenInspectionIsRejected() {
        #expect(StateInspection(inspection(recoverySupported: false, recovery: proposal())) == nil)
    }

    @Test
    func givenMalformedRootOrReceiptIdentity_whenDecoding_thenFailsClosed() {
        var malformed = inspection(recovery: proposal())
        malformed["state_root"] = .string("relative/root")
        #expect(StateInspection(malformed) == nil)

        let resultJSON = #"{"state_root":"/tmp/harflow-fixture-home/.harflow","engine_version":"0.0.2","operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","#
            + #"backup_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","backup_path":"/tmp/backup","status":"completed","phase":"completed"}"#
        let result = JSONValue.parse(Data(resultJSON.utf8))?.objectValue ?? [:]
        #expect(StateRecoveryResult(result) == nil)
    }

    @Test
    func givenStructuredRecoveryRefusal_whenDecoded_thenUnknownDataAndReasonRemainAvailable() {
        let error = ToolError.structuredRefusal(
            code: "state_recovery_failed",
            message: "partial backup",
            data: [
                "reason": .string("future_recovery_reason"),
                "backup_path": .string("/tmp/backup"),
                "future_field": .string("retained")
            ]
        )
        #expect(error.isStateRecoveryRefusal)
        #expect(error.stateRecoveryReason?.rawValue == "future_recovery_reason")
        #expect(error.refusalData?["future_field"]?.stringValue == "retained")
    }

    @Test
    func givenEngineWithoutStateRecoveryCapability_whenInspecting_thenNoRecoveryCommandLaunches() async {
        // given
        let runner = RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return ProcessOutput(
                    exitCode: 0,
                    stdout: json("""
                    {"product":"harflow","format":"harflow.version-info","v":1,"product_version":"0.0.2","component":"engine","state_root":"/tmp/harflow-fixture-home/.harflow","contracts":{"ctl":{"format":"harflow.ctl","v":1}},"capabilities":["ctl.v1"],"os":"darwin","architecture":"arm64"}
                    """),
                    stderr: ""
                )
            }
            Issue.record("state recovery command launched without capability: \(call.arguments)")
            return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner)

        // when
        let result = await client.inspectState()

        // then
        guard case .failure(.unsupportedCommand(_, let command, _)) = result else {
            Issue.record("expected unsupportedCommand, got \(result)")
            return
        }
        #expect(command == "state-inspect")
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test
    func givenOldEngineWithUsageFallback_whenInspecting_thenItIsReportedUnsupportedWithoutDecoding() async {
        // given
        let runner = RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return ProcessOutput(
                    exitCode: 0,
                    stdout: json("""
                    {"product":"harflow","format":"harflow.version-info","v":1,"product_version":"0.0.1","component":"engine","state_root":"/tmp/harflow-fixture-home/.harflow","contracts":{"ctl":{"format":"harflow.ctl","v":1}},"capabilities":["ctl.v1","state-recovery.v1"],"os":"darwin","architecture":"arm64"}
                    """),
                    stderr: ""
                )
            }
            return ProcessOutput(exitCode: 2, stdout: Data(), stderr: "invalid choice: 'state-inspect'")
        }
        let client = CtlClient(executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner)

        // when
        let result = await client.inspectState()

        // then
        guard case .failure(.unsupportedCommand(_, let command, _)) = result else {
            Issue.record("expected unsupportedCommand, got \(result)")
            return
        }
        #expect(command == "state-inspect")
        #expect(runner.allCalls.map(\.arguments) == [["version-info", "--json"], ["state-inspect", "--json"]])
    }
}

// swiftlint:enable line_length
