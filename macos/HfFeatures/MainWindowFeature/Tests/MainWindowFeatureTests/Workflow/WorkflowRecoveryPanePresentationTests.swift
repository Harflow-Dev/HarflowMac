import HfUI
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowRunSidebarSlotTests

struct WorkflowRunSidebarSlotTests {
    @Test(arguments: [true, false], [true, false])
    func givenGraph_whenResolvingSlot_thenSelectionWinsThenRecoveryThenDefault(eligible: Bool, selected: Bool) {
        // given / when
        let slot = WorkflowRunSidebarSlot.resolve(isGraph: true, isRecoveryEligible: eligible, hasNodeSelection: selected)

        // then
        if selected {
            #expect(slot == .selectedNode)
        } else {
            #expect(slot == (eligible ? .recoveryPane : .defaultSidebar))
        }
        #expect(!slot.allowsOverlay)
    }

    @Test(arguments: [true, false], [true, false])
    func givenParallel_whenResolvingSlot_thenEligibleRunUsesOverlayRegardlessOfSelection(eligible: Bool, selected: Bool) {
        // given / when
        let slot = WorkflowRunSidebarSlot.resolve(isGraph: false, isRecoveryEligible: eligible, hasNodeSelection: selected)

        // then
        #expect(slot == (eligible ? .overlay : .defaultSidebar))
        #expect(slot.allowsOverlay == eligible)
    }

    @Test func givenEligibleRun_whenSwitchingGraphAndParallel_thenPaneAndOverlayNeverCoexist() {
        // given
        func slot(_ isGraph: Bool) -> WorkflowRunSidebarSlot {
            .resolve(isGraph: isGraph, isRecoveryEligible: true, hasNodeSelection: false)
        }

        // when / then
        #expect(slot(true) == .recoveryPane)
        #expect(slot(false) == .overlay)
        #expect(slot(true) == .recoveryPane)
    }

    @Test func givenRecoveryPane_whenEligibilityEndsAfterResume_thenSlotReturnsToDefaultSidebar() {
        // given
        let before = WorkflowRunSidebarSlot.resolve(isGraph: true, isRecoveryEligible: true, hasNodeSelection: false)

        // when
        let after = WorkflowRunSidebarSlot.resolve(isGraph: true, isRecoveryEligible: false, hasNodeSelection: false)

        // then — the default sidebar's saved scroll origin is restored by `.default` sizing.
        #expect(before == .recoveryPane)
        #expect(after == .defaultSidebar)
        #expect(after.paneSizing.ownsDefaultInspectorScroll)
    }

    @Test func givenEverySlot_whenSuppressingSummaryQuestion_thenOnlyPaneOrVisibleOverlayDo() {
        // given / when / then
        #expect(WorkflowRunSidebarSlot.recoveryPane.suppressesSummaryQuestion(overlayIsVisible: false))
        #expect(!WorkflowRunSidebarSlot.overlay.suppressesSummaryQuestion(overlayIsVisible: false))
        #expect(WorkflowRunSidebarSlot.overlay.suppressesSummaryQuestion(overlayIsVisible: true))
        #expect(!WorkflowRunSidebarSlot.defaultSidebar.suppressesSummaryQuestion(overlayIsVisible: true))
        #expect(!WorkflowRunSidebarSlot.selectedNode.suppressesSummaryQuestion(overlayIsVisible: true))
    }

    @Test func givenEverySlot_whenGuardingEscape_thenOnlyAVisibleOverlayOwnsIt() {
        // given / when / then
        #expect(WorkflowRunSidebarSlot.overlay.escapeBelongsToOverlay(overlayIsVisible: true))
        #expect(!WorkflowRunSidebarSlot.overlay.escapeBelongsToOverlay(overlayIsVisible: false))
        #expect(!WorkflowRunSidebarSlot.recoveryPane.escapeBelongsToOverlay(overlayIsVisible: true))
        #expect(!WorkflowRunSidebarSlot.selectedNode.escapeBelongsToOverlay(overlayIsVisible: true))
        #expect(!WorkflowRunSidebarSlot.defaultSidebar.escapeBelongsToOverlay(overlayIsVisible: true))
    }

    @Test func givenSlots_whenReadingPaneSizing_thenRecoveryUsesItsOwnWidth() {
        // given / when / then
        #expect(WorkflowRunSidebarSlot.recoveryPane.paneSizing == .recovery)
        #expect(WorkflowRunSidebarSlot.selectedNode.paneSizing == .activity)
        #expect(WorkflowRunSidebarSlot.defaultSidebar.paneSizing == .default)
        #expect(WorkflowRunSidebarSlot.overlay.paneSizing == .default)
        #expect(WorkflowRunLayout.inspectorIdeal(for: .recovery) == 360)
        #expect(WorkflowRunLayout.inspectorIdeal(for: .default) == WorkflowRunLayout.defaultInspectorIdeal)
        #expect(WorkflowRunLayout.inspectorIdeal(for: .activity) == WorkflowRunLayout.inspectorIdeal)
    }

    @Test func givenPresentations_whenOwningDefaultScroll_thenOnlyDefaultSavesAndRestoresIt() {
        // given / when / then
        #expect(WorkflowRunPaneSizing.default.ownsDefaultInspectorScroll)
        #expect(!WorkflowRunPaneSizing.activity.ownsDefaultInspectorScroll)
        #expect(!WorkflowRunPaneSizing.recovery.ownsDefaultInspectorScroll)
    }

    @Test func givenRecoveryWidth_whenClampingForNarrowAndWideWindows_thenKeepsTheSameBoundsAsOtherPanes() {
        // given / when / then
        #expect(WorkflowInspectorWidth.clamped(WorkflowRunLayout.recoveryInspectorIdeal, available: 1440) == 360)
        #expect(WorkflowInspectorWidth.clamped(WorkflowRunLayout.recoveryInspectorIdeal, available: 700) == 299)
    }
}

// MARK: - WorkflowRecoveryFocusRequestTests

struct WorkflowRecoveryFocusRequestTests {
    @Test func givenNoRequest_whenInspecting_thenNothingIsPending() {
        // given / when
        let request = WorkflowRecoveryFocusRequest()

        // then
        #expect(!request.isPending)
    }

    @Test func givenTwoActivations_whenConsumedBetween_thenEachBecomesPendingAgain() {
        // given
        var request = WorkflowRecoveryFocusRequest()

        // when
        request.request()
        let firstPending = request.isPending
        request.consume()
        let afterFirst = request.isPending
        request.request()

        // then
        #expect(firstPending)
        #expect(!afterFirst)
        #expect(request.isPending)
        #expect(request.token == 2)
    }

    @Test func givenPendingRequest_whenCancelled_thenALaterEditorDoesNotTakeFocus() {
        // given
        var request = WorkflowRecoveryFocusRequest()
        request.request()

        // when
        request.cancel()

        // then
        #expect(!request.isPending)
    }

    @Test func givenRepeatedConsume_whenNothingPending_thenItStaysIdle() {
        // given
        var request = WorkflowRecoveryFocusRequest()
        request.request()
        request.consume()

        // when
        request.consume()

        // then
        #expect(!request.isPending)
    }
}

// MARK: - WorkflowRecoveryPanePresentationTests

struct WorkflowRecoveryPanePresentationTests {
    @Test func givenExhaustedRetryEdges_whenChoosingGlyph_thenFailed() {
        // given
        let run = run(["status": .string("paused"), "exhausted_retry_edges": .array([.string("retry")])])

        // when / then
        #expect(WorkflowRecoveryPanePresentation.glyph(for: run) == .failed)
    }

    @Test func givenFailedDelegation_whenChoosingGlyph_thenFailed() {
        // given
        let run = run(["status": .string("failed"), "execution_contract": .string("delegation")])

        // when / then
        #expect(WorkflowRecoveryPanePresentation.glyph(for: run) == .failed)
    }

    @Test(arguments: ["needs_attention", "needs_input", "paused"])
    func givenAttentionStatusWithoutExhaustedEdges_whenChoosingGlyph_thenAttention(status: String) {
        // given
        let run = run(["status": .string(status)])

        // when / then
        #expect(WorkflowRecoveryPanePresentation.glyph(for: run) == .attention)
    }

    @Test func givenNoQuestion_whenReadingText_thenFallbackSentence() {
        // given
        let empty = run(["status": .string("paused")])
        let asked = run(["status": .string("paused"), "input_question": .string("Tests failed.")])

        // when / then
        #expect(WorkflowRecoveryPanePresentation.question(for: empty) == "Scheduling is paused.")
        #expect(WorkflowRecoveryPanePresentation.question(for: asked) == "Tests failed.")
    }

    @Test func givenRunStatus_whenBuildingHeadBadge_thenItEqualsTheHeaderBadge() {
        // given
        let run = run(["status": .string("paused")])

        // when
        let head = WorkflowRunStatusBadge.presentation(status: run.status, isSettling: run.isSettling)

        // then
        #expect(head.label == "Paused")
        #expect(head == WorkflowRunStatusBadge.presentation(status: "paused", isSettling: false))
    }

    private func run(_ raw: [String: JSONValue]) -> WorkflowRunModel {
        var raw = raw
        raw["workflow_run_id"] = .string("pane-run")
        return WorkflowRunModel(raw: raw)
    }
}
