import Combine
import Foundation
import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsViewRepositoryRecoveryTests {
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        func mutate(_ body: (inout Value) -> Void) { body(&value) }
    }

    private final class RecoveryFixture: StateRecoveryRepository, @unchecked Sendable {
        let inspection: StateInspection
        var state: StoreRecoveryState
        var lastCompletedReceipt: StateRecoveryResult?
        let publisher = PassthroughSubject<StoreRecoveryState, Never>()
        let receipt: StateRecoveryResult?

        init(inspection: StateInspection, receipt: StateRecoveryResult?) {
            self.inspection = inspection
            self.state = .confirming(inspection)
            self.receipt = receipt
        }

        func statePublisher() -> AnyPublisher<StoreRecoveryState, Never> { publisher.eraseToAnyPublisher() }
        func report(_: ToolError) {}
        func inspect() async {}
        func requestConfirmation(inspection _: StateInspection) {}
        func cancelConfirmation() {}
        func recover(inspection _: StateInspection) async {
            lastCompletedReceipt = receipt
            state = .incompatible(.refused(code: "state_incompatible", message: "late state change"))
            publisher.send(state)
        }

        func invalidate() {}
    }

    private func inspection() -> StateInspection {
        StateInspection([
            "state_root": .string("/tmp/harflow-fixture-home/.harflow"), "engine_version": .string("0.0.2"),
            "status": .string("interrupted"), "reason": .string("recovery_interrupted"),
            "message": .string("Recovery was interrupted."), "recovery_supported": .bool(true),
            "cooperative_ownership_only": .bool(true), "recovery": .object([
                "operation_id": .string(String(repeating: "a", count: 32)), "confirmation_token": .string("token"),
                "backup_path": .string("/tmp/harflow-backup"), "phase": .string("backup"), "resumable": .bool(false)
            ])
        ])!
    }

    private func receipt(for inspection: StateInspection, operationID: String? = nil) -> StateRecoveryResult {
        StateRecoveryResult([
            "state_root": .string(inspection.stateRoot), "engine_version": .string(inspection.engineVersion),
            "operation_id": .string(operationID ?? inspection.recovery!.operationID),
            "backup_id": .string(operationID ?? inspection.recovery!.operationID),
            "backup_path": .string(inspection.recovery!.backupPath), "status": .string("completed"),
            "phase": .string("completed")
        ])!
    }

    @Test func givenRecoveryCompletesBeforeLateStateChange_whenRecoverStoreReturns_thenWatcherRefreshesOnce() async {
        let current = inspection()
        let recovery = RecoveryFixture(inspection: current, receipt: receipt(for: current))
        let taskList = MockTaskListRepository()
        let refreshCount = Box(0)
        given(taskList).runtimeBecameReady().willProduce { refreshCount.mutate { $0 += 1 } }
        let repository = GeneralSettingsViewRepository(taskListRepository: taskList, stateRecoveryRepository: recovery)

        await repository.recoverStore(current)

        #expect(refreshCount.value == 1)
        #expect(recovery.lastCompletedReceipt == receipt(for: current))
    }

    @Test func givenMismatchedRetainedReceipt_whenRecoveryReturns_thenWatcherDoesNotRefresh() async {
        let current = inspection()
        let oldReceipt = receipt(for: current, operationID: String(repeating: "b", count: 32))
        let recovery = RecoveryFixture(inspection: current, receipt: oldReceipt)
        let taskList = MockTaskListRepository()
        let refreshCount = Box(0)
        given(taskList).runtimeBecameReady().willProduce { refreshCount.mutate { $0 += 1 } }
        let repository = GeneralSettingsViewRepository(taskListRepository: taskList, stateRecoveryRepository: recovery)

        await repository.recoverStore(current)

        #expect(refreshCount.value == 0)
    }
}
