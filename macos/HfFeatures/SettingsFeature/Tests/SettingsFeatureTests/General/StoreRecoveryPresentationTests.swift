import Foundation
import HfRepository
import MonitorCore
@testable import SettingsFeature
import Testing

@Suite struct StoreRecoveryPresentationTests {
    private func inspection(resumable: Bool = false, supported: Bool = true) -> StateInspection {
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

    @Test func givenProductionBuild_whenReadingTheFlag_thenRecoveryActionsAreHidden() {
        // given / when / then
        #expect(StoreRecoveryPresentation.recoveryActionsAvailable == false)
    }

    @Test func givenInterruptedRecoverableInspection_whenPresenting_thenNoRecoveryControlsHintOrWarningAreShown() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection()))
        // then
        #expect(sut.requestTitle == nil)
        #expect(!sut.confirming)
        #expect(!sut.showsArchivalWarning)
        #expect(!sut.showsRetryHint)
        #expect(sut.canInspect)
        #expect(sut.phase == "backup")
        #expect(sut.title == "Recovery was interrupted")
    }

    @Test func givenInterruptedResumableInspection_whenPresenting_thenNoRequestHintOrWarningIsShown() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection(resumable: true)))
        // then
        #expect(sut.requestTitle == nil)
        #expect(!sut.showsArchivalWarning)
        #expect(!sut.showsRetryHint)
    }

    @Test func givenConfirmationPublishedByTheUseCase_whenPresenting_thenItRendersLikeAnInspection() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .confirming(inspection()))
        // then
        #expect(!sut.confirming)
        #expect(sut.canInspect)
        #expect(sut.requestTitle == nil)
        #expect(!sut.showsArchivalWarning)
        #expect(!sut.showsRetryHint)
        #expect(sut.title == "Recovery was interrupted")
    }

    @Test func givenIncompatibleErrorWithPhase_whenPresenting_thenNoRetryHintIsShownAndInspectIsAvailable() {
        // given
        let error = ToolError.structuredRefusal(code: "state_incompatible", message: "Incompatible store.", data: [
            "phase": .string("backup")
        ])
        // when
        let sut = StoreRecoveryPresentation(state: .incompatible(error))
        // then
        #expect(sut.phase == "backup")
        #expect(!sut.showsRetryHint)
        #expect(sut.canInspect)
    }

    @Test func givenRetainedReceipt_whenPresenting_thenRevealStaysAvailable() {
        // given / when
        let sut = StoreRecoveryPresentation(state: .inspected(inspection()), receipt: receipt())
        // then
        #expect(sut.canReveal)
        #expect(sut.completedBackupPath == "/tmp/harflow-backup")
        #expect(sut.canInspect)
    }
}
