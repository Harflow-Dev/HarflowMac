import Foundation
import HfRepository
import MonitorCore
@testable import SettingsFeature
import Testing

@Suite struct StoreRecoveryPresentationTests {
    private func inspection(
        status: String = "interrupted", reason: String = "recovery_interrupted", message: String = "The previous recovery was interrupted.",
        resumable: Bool = false, supported: Bool = true
    ) -> StateInspection {
        var value: [String: JSONValue] = [
            "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"),
            "status": .string(status), "reason": .string(reason), "message": .string(message),
            "recovery_supported": .bool(supported), "cooperative_ownership_only": .bool(true)
        ]
        if supported {
            value["recovery"] = .object([
                "operation_id": .string("0123456789abcdef0123456789abcdef"),
                "confirmation_token": .string("token"), "backup_path": .string("/tmp/harflow-backup"),
                "phase": .string("backup"), "resumable": .bool(resumable)
            ])
        }
        return StateInspection(value)!
    }

    private func receipt() -> StateRecoveryResult {
        StateRecoveryResult([
            "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"),
            "operation_id": .string("0123456789abcdef0123456789abcdef"),
            "backup_id": .string("0123456789abcdef0123456789abcdef"),
            "backup_path": .string("/tmp/harflow-backup"), "status": .string("completed"), "phase": .string("completed")
        ])!
    }

    private func labels(_ sut: StoreRecoveryPresentation) -> [String] { sut.rows.map(\.label) }

    @Test func givenProductionBuild_whenReadingTheFlag_thenRecoveryActionsAreHidden() {
        // given / when / then
        #expect(StoreRecoveryPresentation.recoveryActionsAvailable == false)
    }

    // MARK: - Runtime and idle

    @Test(arguments: [
        StoreRecoveryState.idle, .inspecting, .completed(StateRecoveryResult([
            "state_root": .string("/tmp/harflow-state"), "engine_version": .string("0.0.2"),
            "operation_id": .string("0123456789abcdef0123456789abcdef"),
            "backup_id": .string("0123456789abcdef0123456789abcdef"),
            "backup_path": .string("/tmp/harflow-backup"), "status": .string("completed"), "phase": .string("completed")
        ])!), .failed(.refused(code: "x", message: "y"), inspection: nil)
    ])
    func givenRuntimeNotReady_whenPresentingAnyStoreState_thenTheWaitingRowShowsWithInspectDisabled(_ state: StoreRecoveryState) {
        // given / when
        let sut = StoreRecoveryPresentation(state: state, runtimeReady: false)

        // then
        #expect(sut.title == "Task store")
        #expect(sut.glyph == nil)
        #expect(sut.message == StoreRecoveryPresentation.waitingMessage)
        #expect(sut.rows.isEmpty)
        #expect(sut.canInspect)
        #expect(!sut.inspectEnabled)
        #expect(!sut.showsInterruptedNote)
    }

    @Test func givenRuntimeNotReadyAndAnInterruptedInspection_whenPresenting_thenNoNoteOrRowsAreShown() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection()), runtimeReady: false)

        // then
        #expect(!sut.showsInterruptedNote)
        #expect(sut.rows.isEmpty)
        #expect(!sut.inspectEnabled)
    }

    @Test func givenReadyRuntimeNotInspected_whenPresenting_thenTheWaitingCopyShowsWithInspectEnabled() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .idle)

        // then
        #expect(sut.title == "Task store")
        #expect(sut.glyph == nil)
        #expect(sut.message == StoreRecoveryPresentation.waitingMessage)
        #expect(sut.rows.isEmpty)
        #expect(sut.canInspect)
        #expect(sut.inspectEnabled)
    }

    @Test func givenInspecting_whenPresenting_thenItShowsABusyRowWithNoButton() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspecting)

        // then
        #expect(sut.title == "Inspecting task store…")
        #expect(sut.glyph == .busy)
        #expect(sut.message == StoreRecoveryPresentation.waitingMessage)
        #expect(sut.rows.isEmpty)
        #expect(!sut.canInspect)
    }

    // MARK: - Inspected

    @Test func givenCompatibleInspection_whenPresenting_thenOnlyTheDoneTitleAndInspectShow() {
        // given
        let ready = inspection(status: "ready", reason: "compatible", message: "Store is compatible.", supported: false)

        // when
        let sut = StoreRecoveryPresentation(state: .inspected(ready))

        // then
        #expect(sut.title == "Task store is compatible")
        #expect(sut.glyph == .done)
        #expect(sut.message == nil)
        #expect(sut.rows.isEmpty)
        #expect(sut.canInspect)
        #expect(!sut.showsInterruptedNote)
    }

    @Test func givenMissingInspection_whenPresenting_thenStateRootAndReasonShow() {
        // given
        let missing = inspection(status: "missing", reason: "missing_root", message: "State root has not been initialized", supported: false)

        // when
        let sut = StoreRecoveryPresentation(state: .inspected(missing))

        // then
        #expect(sut.title == "Task store has not been created")
        #expect(sut.glyph == .attention)
        #expect(sut.message == "State root has not been initialized")
        #expect(labels(sut) == ["State root", "Reason"])
        #expect(!sut.showsInterruptedNote)
    }

    @Test func givenIncompatibleInspectionWithAProposal_whenPresenting_thenOnlyStateRootAndReasonShow() {
        // given
        let incompatible = inspection(status: "incompatible", reason: "unmarked_nonempty", message: "Unmarked state root contains data")

        // when
        let sut = StoreRecoveryPresentation(state: .inspected(incompatible))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.glyph == .attention)
        #expect(labels(sut) == ["State root", "Reason"])
        #expect(!sut.showsInterruptedNote)
    }

    @Test func givenInterruptedRecoverableInspection_whenPresenting_thenTheNoteAndEvidenceShowWithoutRecoveryControls() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection()))

        // then
        #expect(sut.title == "Recovery was interrupted")
        #expect(sut.glyph == .attention)
        #expect(labels(sut) == ["State root", "Reason", "Backup path", "Recovery operation", "Phase"])
        #expect(sut.phase == "backup")
        #expect(sut.showsInterruptedNote)
        #expect(sut.requestTitle == nil)
        #expect(!sut.confirming)
        #expect(!sut.showsArchivalWarning)
        #expect(sut.canInspect)
    }

    @Test func givenInterruptedResumableInspection_whenPresenting_thenTheNoteShowsWithoutRequestOrWarning() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection(resumable: true)))

        // then
        #expect(sut.showsInterruptedNote)
        #expect(sut.requestTitle == nil)
        #expect(!sut.showsArchivalWarning)
    }

    @Test func givenConfirmationPublishedByTheUseCase_whenPresenting_thenItRendersLikeAnInspection() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .confirming(inspection()))

        // then
        #expect(!sut.confirming)
        #expect(sut.canInspect)
        #expect(sut.requestTitle == nil)
        #expect(!sut.showsArchivalWarning)
        #expect(sut.title == "Recovery was interrupted")
    }

    // MARK: - Refusals

    @Test func givenIncompatibleRefusalWithANonInterruptedPhase_whenPresenting_thenNoNoteOrEvidenceRowsShow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Incompatible store.", data: [
            "phase": .string("backup"), "state_root": .string("/tmp/harflow-state"), "reason": .string("unmarked_nonempty")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.glyph == .attention)
        #expect(labels(sut) == ["State root", "Reason"])
        #expect(!sut.showsInterruptedNote)
        #expect(sut.canInspect)
    }

    @Test func givenInterruptedRefusal_whenPresenting_thenTheTitleEvidenceAndNoteShow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Explicit recovery must be resumed", data: [
            "reason": .string("recovery_interrupted"), "state_root": .string("/tmp/harflow-state"),
            "backup_path": .string("/tmp/harflow-backup"), "operation_id": .string("0123456789abcdef0123456789abcdef"),
            "phase": .string("copying")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))

        // then
        #expect(sut.title == "Recovery was interrupted")
        #expect(sut.glyph == .attention)
        #expect(labels(sut) == ["State root", "Reason", "Backup path", "Recovery operation", "Phase"])
        #expect(sut.showsInterruptedNote)
    }

    @Test func givenMissingRootRefusal_whenPresenting_thenTheNotCreatedTitleShows() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "No store.", data: [
            "reason": .string("missing_root"), "state_root": .string("/tmp/harflow-state")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))

        // then
        #expect(sut.title == "Task store has not been created")
        #expect(!sut.showsInterruptedNote)
    }

    // MARK: - Failures and completion

    @Test func givenInspectionFailureThatIsARefusal_whenPresenting_thenTheEngineMessageAndOnlyTheCodeRowShow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Inspect failed.", data: [
            "reason": .string("recovery_interrupted"), "state_root": .string("/tmp/harflow-state"), "phase": .string("copying")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .failed(error, inspection: nil))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.glyph == .attention)
        #expect(sut.message == "Inspect failed.")
        #expect(sut.rows == [.init(label: "Code", value: "state_incompatible")])
        #expect(!sut.showsInterruptedNote)
        #expect(sut.canInspect)
    }

    @Test func givenInspectionFailureThatIsAMissingStateInspectCommand_whenPresenting_thenTheMissingFeatureSentenceShowsWithNoRows() {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "state-inspect", detail: "Missing capability state-recovery.v1")

        // when
        let sut = StoreRecoveryPresentation(state: .failed(error, inspection: nil))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.message == "This Harflow runtime can't inspect the task store. Update Harflow to use it.")
        #expect(sut.rows.isEmpty)
        #expect(sut.canInspect)
    }

    @Test func givenAnUnsupportedCommandForADifferentCommand_whenPresenting_thenTheToolMessageShowsNotTheMissingFeatureSentence() {
        // given
        let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "state-recover", detail: "Missing capability state-recovery.v1")

        // when
        let sut = StoreRecoveryPresentation(state: .failed(error, inspection: nil))

        // then
        #expect(sut.message == error.displayMessage)
        #expect(sut.message?.contains("Update Harflow") != true)
    }

    @Test func givenInspectionFailureThatIsNotARefusal_whenPresenting_thenTheToolMessageShowsWithNoRows() {
        // given
        let error = ToolError.timedOut(tool: "harflow-ctl", seconds: 30)

        // when
        let sut = StoreRecoveryPresentation(state: .failed(error, inspection: nil))

        // then
        #expect(sut.message == "harflow-ctl did not answer within 30 s.")
        #expect(sut.rows.isEmpty)
    }

    @Test func givenRefusalWithAReason_whenPresenting_thenTheMessageHasNoCodeAndThereIsNoCodeRow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Unsupported state root: foreign store marker", data: [
            "reason": .string("foreign_store"), "state_root": .string("/tmp/harflow-state")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.message == "Unsupported state root: foreign store marker")
        #expect(labels(sut) == ["State root", "Reason"])
        #expect(sut.rows.last?.value == "foreign_store")
    }

    @Test func givenRefusalWithoutAReason_whenPresenting_thenTheCodeRowReplacesTheReasonRow() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Store refused.", data: [
            "state_root": .string("/tmp/harflow-state")
        ])

        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))

        // then
        #expect(sut.title == "Task store needs attention")
        #expect(sut.message == "Store refused.")
        #expect(sut.rows == [.init(label: "State root", value: "/tmp/harflow-state"), .init(label: "Code", value: "state_incompatible")])
    }

    @Test func givenCompletedRecovery_whenPresenting_thenNoNoteShowsAndRevealIsNotOffered() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .completed(receipt()))

        // then
        #expect(sut.title == "Task store is ready")
        #expect(sut.glyph == .done)
        #expect(!sut.showsInterruptedNote)
        #expect(sut.canReveal)
        #expect(!sut.offersReveal)
    }

    @Test func givenRetainedReceipt_whenPresenting_thenRevealIsNotOffered() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection()), receipt: receipt())

        // then
        #expect(sut.canReveal)
        #expect(sut.completedBackupPath == "/tmp/harflow-backup")
        #expect(!sut.offersReveal)
        #expect(sut.canInspect)
    }
}
