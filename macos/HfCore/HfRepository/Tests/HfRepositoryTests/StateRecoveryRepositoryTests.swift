import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

// swiftlint:disable line_length

@Suite(.serialized)
struct StateRecoveryRepositoryTests {
    private let root = "/tmp/harflow-fixture-home/.harflow"
    private let operation = String(repeating: "a", count: 32)

    private func json(_ text: String) -> Data { Data(text.utf8) }

    private func versionInfo() -> Data {
        json(#"{"product":"harflow","format":"harflow.version-info","v":1,"product_version":"0.0.2","component":"engine","state_root":"/tmp/harflow-fixture-home/.harflow","contracts":{"ctl":{"format":"harflow.ctl","v":1}},"capabilities":["ctl.v1","state-recovery.v1"],"os":"darwin","architecture":"arm64"}"#)
    }

    private func inspection() -> Data {
        json(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.2","result":{"state_root":"/tmp/harflow-fixture-home/.harflow","engine_version":"0.0.2","status":"incompatible","reason":"future_reason","message":"store refused","recovery_supported":true,"cooperative_ownership_only":true,"recovery":{"operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","confirmation_token":"opaque","backup_path":"/tmp/harflow-fixture-home/.harflow-backup-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","phase":"proposed","resumable":false}}}"#)
    }

    @Test
    func givenInspection_whenConfirmedThenCancelled_thenRecoveryCommandIsNeverLaunched() async {
        let runner = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: versionInfo(), stderr: ""))
            }
            if call.arguments == ["state-inspect", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: inspection(), stderr: ""))
            }
            Issue.record("unexpected command: \(call.arguments)")
            return .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected"))
        }
        let environment = MockToolEnvironmentRepository()
        let client = CtlClient(
            executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner
        )
        given(environment).ctl().willReturn(.success(client))
        let repository = StateRecoveryRepositoryImpl(toolEnvironment: environment)

        await repository.inspect()
        guard case .inspected(let inspection) = repository.state else {
            Issue.record("inspection should produce an inspected state: \(repository.state)")
            return
        }
        repository.requestConfirmation(inspection: inspection)
        #expect({ if case .confirming = repository.state { return true }; return false }())
        repository.cancelConfirmation()
        #expect({ if case .inspected = repository.state { return true }; return false }())
        #expect(runner.allCalls.map(\.arguments).filter { $0.first == "state-recover" }.isEmpty)
    }

    @Test
    func givenStaleInspection_whenRequestingConfirmation_thenStateDoesNotAdvance() async {
        let runner = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: versionInfo(), stderr: ""))
            }
            return .success(ProcessOutput(exitCode: 0, stdout: inspection(), stderr: ""))
        }
        let environment = MockToolEnvironmentRepository()
        let client = CtlClient(
            executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner
        )
        given(environment).ctl().willReturn(.success(client))
        let repository = StateRecoveryRepositoryImpl(toolEnvironment: environment)
        await repository.inspect()
        let stale = StateInspection([
            "state_root": .string(root), "engine_version": .string("0.0.2"), "status": .string("incompatible"),
            "reason": .string("future_reason"), "message": .string("store refused"),
            "recovery_supported": .bool(true), "cooperative_ownership_only": .bool(true),
            "recovery": .object([
                "operation_id": .string(operation), "confirmation_token": .string("different"),
                "backup_path": .string("/tmp/backup"), "phase": .string("proposed"),
                "resumable": .bool(false)
            ])
        ])!
        repository.requestConfirmation(inspection: stale)
        #expect({ if case .inspected = repository.state { return true }; return false }(), "state=\(repository.state)")
    }

    @Test
    func givenSuspendedInspection_whenInvalidated_thenOldResultIsDiscardedAndNewInspectionWaitsForSingleflight() async {
        // given
        let entered = AsyncGate()
        let release = AsyncGate()
        let version = versionInfo()
        let state = inspection()
        let runner = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: version, stderr: ""))
            }
            if call.arguments == ["state-inspect", "--json"] {
                entered.open()
                release.waitSync()
                return .success(ProcessOutput(exitCode: 0, stdout: state, stderr: ""))
            }
            Issue.record("unexpected command: \(call.arguments)")
            return .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected"))
        }
        let environment = MockToolEnvironmentRepository()
        let client = CtlClient(
            executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner
        )
        given(environment).ctl().willReturn(.success(client))
        let repository = StateRecoveryRepositoryImpl(toolEnvironment: environment)
        let first = Task { await repository.inspect() }
        entered.waitSync()

        // when
        repository.invalidate()
        release.open()
        await first.value

        // then
        #expect(repository.state == .idle)
        #expect(runner.calls.filter { $0.arguments == ["state-inspect", "--json"] }.count == 1)
    }

    @Test
    func givenCompletedReceipt_whenLateRefusalArrives_thenReceiptRemainsAndNewIncompatibilityCanBeSurfacedAfterInvalidation() async {
        let runner = StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: versionInfo(), stderr: ""))
            }
            if call.arguments == ["state-inspect", "--json"] {
                return .success(ProcessOutput(exitCode: 0, stdout: inspection(), stderr: ""))
            }
            if call.arguments.first == "state-recover" {
                let receipt = json(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.2","result":{"state_root":"/tmp/harflow-fixture-home/.harflow","engine_version":"0.0.2","status":"completed","phase":"completed","operation_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","backup_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","backup_path":"/tmp/harflow-fixture-home/.harflow-backup-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}}"#)
                return .success(ProcessOutput(exitCode: 0, stdout: receipt, stderr: ""))
            }
            Issue.record("unexpected command: \(call.arguments)")
            return .success(ProcessOutput(exitCode: 1, stdout: Data(), stderr: "unexpected"))
        }
        let environment = MockToolEnvironmentRepository()
        let client = CtlClient(executable: "/fake/ctl", environment: ["HOME": "/tmp/harflow-fixture-home"], runner: runner)
        given(environment).ctl().willReturn(.success(client))
        let repository = StateRecoveryRepositoryImpl(toolEnvironment: environment)

        await repository.inspect()
        guard case .inspected(let current) = repository.state else {
            Issue.record("inspection should complete before recovery")
            return
        }
        repository.requestConfirmation(inspection: current)
        await repository.recover(inspection: current)
        guard case .completed(let receipt) = repository.state else {
            Issue.record("recovery should retain its completed receipt")
            return
        }

        #expect(repository.lastCompletedReceipt == receipt)
        let lateRefusal = ToolError.structuredRefusal(code: "state_recovery_failed", message: "late stale result", data: [:])
        repository.report(lateRefusal)
        #expect(repository.state == .incompatible(lateRefusal))
        #expect(repository.lastCompletedReceipt == receipt)

        repository.invalidate()
        let genuine = ToolError.structuredRefusal(code: "state_incompatible", message: "store changed", data: [
            "reason": .string("active_owner")
        ])
        repository.report(genuine)
        #expect(repository.state == .incompatible(genuine))
        #expect(repository.lastCompletedReceipt == nil)
    }
}

// swiftlint:enable line_length
