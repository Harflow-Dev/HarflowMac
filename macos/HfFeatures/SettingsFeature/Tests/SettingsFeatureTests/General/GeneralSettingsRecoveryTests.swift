import Combine
import Foundation
import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
@Suite struct GeneralSettingsRecoveryTests {
    private final class RecoveryUseCase: GeneralSettingsUseCase, RuntimeSetupObserving, StoreRecoveryUseCase, @unchecked Sendable {
        var recoveryState: StoreRecoveryState = .idle
        let recoverySubject = PassthroughSubject<StoreRecoveryState, Never>()
        var runtimeSetupState: RuntimeSetupState = .ready
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()
        var lastCompletedReceipt: StateRecoveryResult?
        var result: StoreRecoveryState = .idle
        var inspectCount = 0
        var confirmation: StateInspection?
        var recovered: StateInspection?

        var toolDirectory = ""
        var openWindowOnStart = true
        var notifyOnFinish = true
        var notifyOnNeedsYou = true
        var searchDirectories: [String] = []

        func installStatePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        func retryRuntime() async {}
        func resolve(_: String) -> ToolResolution { .notFound }
        func toolDirectoryPublisher() -> AnyPublisher<String, Never> { Just(toolDirectory).eraseToAnyPublisher() }
        func openWindowOnStartPublisher() -> AnyPublisher<Bool, Never> { Just(openWindowOnStart).eraseToAnyPublisher() }
        func notifyOnFinishPublisher() -> AnyPublisher<Bool, Never> { Just(notifyOnFinish).eraseToAnyPublisher() }
        func notifyOnNeedsYouPublisher() -> AnyPublisher<Bool, Never> { Just(notifyOnNeedsYou).eraseToAnyPublisher() }
        func tasksPublisher() -> AnyPublisher<[TaskInfo], Never> { Just([]).eraseToAnyPublisher() }
        func hasListedPublisher() -> AnyPublisher<Bool, Never> { Just(false).eraseToAnyPublisher() }
        func listErrorPublisher() -> AnyPublisher<ToolError?, Never> { Just(nil).eraseToAnyPublisher() }
        func setToolDirectory(_: String) {}
        func setOpenWindowOnStart(_: Bool) {}
        func setNotifyOnFinish(_: Bool) {}
        func setNotifyOnNeedsYou(_: Bool) {}

        func runtimeSetupPublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        func installRuntime() async {}
        func recoveryStatePublisher() -> AnyPublisher<StoreRecoveryState, Never> { recoverySubject.eraseToAnyPublisher() }
        func inspectStore() async {
            inspectCount += 1
            publish(.inspected(Self.inspection()))
        }

        func confirmRecovery(_ inspection: StateInspection) { confirmation = inspection; publish(.confirming(inspection)) }
        func cancelRecovery() { if case .confirming(let inspection) = recoveryState { publish(.inspected(inspection)) } }
        func recoverStore(_ inspection: StateInspection) async {
            recovered = inspection
            if case .completed(let receipt) = result { lastCompletedReceipt = receipt }
            publish(result)
        }

        func publish(_ state: StoreRecoveryState) {
            recoveryState = state
            if case .completed(let receipt) = state { lastCompletedReceipt = receipt }
            recoverySubject.send(state)
        }

        static func inspection(supported: Bool = true) -> StateInspection {
            var value: [String: JSONValue] = [
                "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"),
                "status": .string("interrupted"), "reason": .string("recovery_interrupted"),
                "message": .string("The previous recovery was interrupted."),
                "recovery_supported": .bool(supported), "cooperative_ownership_only": .bool(true)
            ]
            if supported {
                value["recovery"] = .object([
                    "operation_id": .string("0123456789abcdef0123456789abcdef"),
                    "confirmation_token": .string("token"), "backup_path": .string("/tmp/harflow-backup"),
                    "phase": .string("backup"), "resumable": .bool(false)
                ])
            }
            return StateInspection(value)!
        }

        static func receipt() -> StateRecoveryResult {
            StateRecoveryResult([
                "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"),
                "operation_id": .string("0123456789abcdef0123456789abcdef"),
                "backup_id": .string("0123456789abcdef0123456789abcdef"),
                "backup_path": .string("/tmp/harflow-backup"), "status": .string("completed"),
                "phase": .string("completed")
            ])!
        }
    }

    @Test func givenInterruptedInspection_whenRequestIsCancelled_thenRecoveryRemainsUnstarted() async {
        let useCase = RecoveryUseCase()
        let sut = GeneralSettingsVM(useCase: useCase)
        sut.didAppear()
        sut.didTapInspectStore()
        await waitUntil { useCase.inspectCount == 1 && { if case .inspected = useCase.recoveryState { true } else { false } }() }

        sut.didTapRequestRecovery()
        #expect({ if case .confirming = useCase.recoveryState { true } else { false } }())
        sut.didTapCancelRecovery()

        #expect({ if case .inspected = useCase.recoveryState { true } else { false } }())
        #expect(useCase.recovered == nil)
    }

    @Test func givenUnsupportedInspection_whenRequestingRecovery_thenItDoesNotEnterConfirmation() async {
        let useCase = RecoveryUseCase()
        let sut = GeneralSettingsVM(useCase: useCase)
        sut.didAppear()
        useCase.publish(.inspected(RecoveryUseCase.inspection(supported: false)))

        sut.didTapRequestRecovery()

        #expect({ if case .inspected = useCase.recoveryState { true } else { false } }())
        #expect(sut.recoveryPresentation.requestTitle == nil)
    }

    @Test func givenConfirmedRecovery_whenEngineReturnsReceipt_thenReceiptIsRetainedAndRevealRoutesIt() async {
        let useCase = RecoveryUseCase()
        useCase.result = .completed(RecoveryUseCase.receipt())
        let routing = MockStoreRecoveryRouting()
        var revealed: StateRecoveryResult?
        given(routing)
.revealBackup(.any)
.willProduce { revealed = $0 }
        let sut = GeneralSettingsVM(useCase: useCase, recoveryRouting: routing)
        sut.didAppear()
        useCase.publish(.inspected(RecoveryUseCase.inspection()))
        await waitUntil { if case .inspected = sut.recoveryState { true } else { false } }
        sut.didTapRequestRecovery()
        await waitUntil { if case .confirming = sut.recoveryState { true } else { false } }
        sut.didTapConfirmRecovery()
        await waitUntil { useCase.recovered != nil }
        await waitUntil { if case .completed = sut.recoveryState { true } else { false } }

        #expect({ if case .completed = useCase.recoveryState { true } else { false } }())
        #expect(sut.recoveryPresentation.canReveal)
        sut.didTapRevealBackup()
        #expect(revealed == RecoveryUseCase.receipt())
    }

    @Test func givenRecoveryFailureWithPartialBackup_whenPublished_thenInspectionEvidenceRemainsVisible() async {
        let useCase = RecoveryUseCase()
        let inspection = RecoveryUseCase.inspection()
        let error = ToolError.structuredRefusal(code: "state_recovery_failed", message: "Backup completed but reset failed.", data: [
            "backup_path": .string("/tmp/harflow-backup")
        ])
        let sut = GeneralSettingsVM(useCase: useCase)
        sut.didAppear()
        useCase.publish(.failed(error, inspection: inspection))
        await waitUntil { if case .failed = sut.recoveryState { true } else { false } }

        #expect(sut.recoveryPresentation.message == "Backup completed but reset failed. (state_recovery_failed)")
        #expect(sut.recoveryPresentation.backupPath == "/tmp/harflow-backup")
        #expect(sut.recoveryPresentation.operationID == inspection.recovery?.operationID)
    }

    @Test func givenRetainedReceipt_whenRecoveryStateChanges_thenRevealStillUsesTheCompletedReceipt() async {
        let useCase = RecoveryUseCase()
        let routing = MockStoreRecoveryRouting()
        var revealed: StateRecoveryResult?
        given(routing)
.revealBackup(.any)
.willProduce { revealed = $0 }
        let sut = GeneralSettingsVM(useCase: useCase, recoveryRouting: routing)
        sut.didAppear()
        let receipt = RecoveryUseCase.receipt()
        useCase.publish(.completed(receipt))
        await waitUntil { if case .completed = sut.recoveryState { true } else { false } }
        useCase.publish(.failed(.structuredRefusal(code: "state_incompatible", message: "new refusal", data: [:]), inspection: nil))
        await waitUntil { if case .failed = sut.recoveryState { true } else { false } }

        sut.didTapRevealBackup()

        #expect(revealed == receipt)
    }
}
