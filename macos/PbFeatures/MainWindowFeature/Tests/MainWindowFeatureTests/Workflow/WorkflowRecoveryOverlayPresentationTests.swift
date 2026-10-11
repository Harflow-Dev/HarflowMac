@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowRecoveryOverlayPresentationTests

struct WorkflowRecoveryOverlayPresentationTests {
    @Test func givenFirstEligibleRun_whenSynchronizing_thenItAutoOpensOnceWithoutFocusRequest() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()

        // when
        presentation.syncEligibility(runID: "run-a")

        // then
        #expect(presentation.isOpen)
        #expect(!presentation.isEditorFocusRequested)
        #expect(presentation.autoPresentedRunIDs == ["run-a"])
        #expect(presentation.currentRunID == "run-a")
        #expect(presentation.isVisible(runID: "run-a"))
        #expect(!presentation.isVisible(runID: "run-b"))
    }

    @Test func givenDismissedRun_whenPollingAndQuestionChange_thenItDoesNotReopen() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")
        presentation.closeExplicitly()

        // when
        presentation.syncEligibility(runID: "run-a")
        presentation.autoPresentIfNeeded(runID: "run-a")

        // then
        #expect(!presentation.isOpen)
        #expect(!presentation.isEditorFocusRequested)
        #expect(!presentation.isVisible(runID: "run-a"))
    }

    @Test func givenDismissedRunA_whenRunBOpensAndRunAReturns_thenItStaysClosed() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")
        presentation.closeExplicitly()

        // when
        presentation.syncEligibility(runID: "run-b")
        presentation.closeExplicitly()
        presentation.syncEligibility(runID: "run-a")

        // then
        #expect(!presentation.isOpen)
        #expect(presentation.autoPresentedRunIDs == ["run-a", "run-b"])
        #expect(presentation.currentRunID == "run-a")
    }

    @Test func givenOpenRun_whenPollingTheSameRun_thenItStaysOpen() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")

        // when
        presentation.syncEligibility(runID: "run-a")

        // then — identical refreshes cannot close or recreate the panel.
        #expect(presentation.isOpen)
        #expect(!presentation.isEditorFocusRequested)
    }

    @Test func givenPreviouslySeenRunB_whenRunBBecomesEligibleAgain_thenItDoesNotAutoOpenOrFocus() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-b")
        presentation.closeExplicitly()

        // when
        presentation.syncEligibility(runID: "run-b")

        // then
        #expect(!presentation.isOpen)
        #expect(!presentation.isEditorFocusRequested)
    }

    @Test func givenOpenRunA_whenAlreadySeenRunBBecomesCurrent_thenItHidesWithoutFocusRequest() {
        // given — both run IDs have already had their one automatic presentation.
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-b")
        presentation.closeExplicitly()
        presentation.syncEligibility(runID: "run-a")
        #expect(presentation.isOpen)

        // when
        presentation.syncEligibility(runID: "run-b")

        // then — changing the selected run cannot leave A's panel over B's content.
        #expect(!presentation.isOpen)
        #expect(!presentation.isEditorFocusRequested)
    }

    @Test func givenIneligibleOrEmptyRun_whenSynchronizing_thenItClosesWithoutConsumingAnID() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")

        // when
        presentation.syncEligibility(runID: nil)
        presentation.autoPresentIfNeeded(runID: "")

        // then
        #expect(!presentation.isOpen)
        #expect(presentation.autoPresentedRunIDs == ["run-a"])
    }

    @Test func givenNewPresentationInstance_whenSynchronizingPreviouslySeenID_thenItAutoOpens() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()

        // when
        presentation.syncEligibility(runID: "run-a")

        // then — lifetime is local to this screen instance.
        #expect(presentation.isOpen)
        #expect(presentation.autoPresentedRunIDs == ["run-a"])
    }

    @Test func givenOpenPanel_whenOpeningFromEligibleBadge_thenItRemainsOpenAndRequestsFocus() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")

        // when
        presentation.openFromBadge()
        presentation.openFromBadge()

        // then
        #expect(presentation.isOpen)
        #expect(presentation.isEditorFocusRequested)
        #expect(presentation.autoPresentedRunIDs == ["run-a"])
    }

    @Test func givenBadgeOpenedRun_whenPollingTheSameRun_thenFocusRequestRemainsPending() {
        // given
        var presentation = WorkflowRecoveryOverlayPresentation()
        presentation.syncEligibility(runID: "run-a")
        presentation.openFromBadge()

        // when
        presentation.syncEligibility(runID: "run-a")

        // then — polling must not undo an explicit focus request.
        #expect(presentation.isOpen)
        #expect(presentation.isEditorFocusRequested)
    }

    @Test(arguments: ["needs_attention", "paused", "needs_input"])
    func givenEligibleLoadedRun_whenCheckingEligibility_thenReturnsItsNonemptyID(status: String) {
        // given
        let run = run(id: "run-a", status: status)

        // when / then
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: run, initialLoadingKind: nil, initialLoadFailed: false
        ) == "run-a")
    }

    @Test func givenFailedDelegationRun_whenCheckingEligibility_thenReturnsItsID() {
        // given
        let run = run(id: "run-a", status: "failed", delegation: true)

        // when / then
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: run, initialLoadingKind: nil, initialLoadFailed: false
        ) == "run-a")
    }

    @Test func givenLoadingFailedOrOwnedRun_whenCheckingEligibility_thenReturnsNil() {
        // given
        let eligible = run(id: "run-a", status: "needs_attention")
        let callerOwned = run(id: "run-a", status: "needs_attention", owner: "caller")
        let child = WorkflowRunModel(raw: [
            "workflow_run_id": .string("run-a"), "status": .string("needs_attention"),
            "interaction_owner": .string("monitor"), "parent_workflow_run_id": .string("parent")
        ])
        let builder = run(id: "run-a", status: "needs_attention", kind: "builder")

        // when / then
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: eligible, initialLoadingKind: "loading", initialLoadFailed: false
        ) == nil)
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: eligible, initialLoadingKind: nil, initialLoadFailed: true
        ) == nil)
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: callerOwned, initialLoadingKind: nil, initialLoadFailed: false
        ) == nil)
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: child, initialLoadingKind: nil, initialLoadFailed: false
        ) == nil)
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: builder, initialLoadingKind: nil, initialLoadFailed: false
        ) == nil)
    }

    @Test func givenEmptyIDOrNonRecoveryStatus_whenCheckingEligibility_thenReturnsNil() {
        // given
        let empty = run(id: "", status: "needs_attention")
        let completed = run(id: "run-a", status: "completed")

        // when / then
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: empty, initialLoadingKind: nil, initialLoadFailed: false
        ) == nil)
        #expect(WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: completed, initialLoadingKind: nil, initialLoadFailed: false
        ) == nil)
    }

    private func run(id: String, status: String, delegation: Bool = false,
                     owner: String = "monitor", kind: String = "") -> WorkflowRunModel {
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string(id), "status": .string(status),
            "interaction_owner": .string(owner)
        ]
        if delegation { raw["execution_contract"] = .string("delegation") }
        if !kind.isEmpty { raw["kind"] = .string(kind) }
        return WorkflowRunModel(raw: raw)
    }
}
