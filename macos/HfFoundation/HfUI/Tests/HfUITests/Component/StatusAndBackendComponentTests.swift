@testable import HfUI
import MonitorCore
import Testing

@Suite struct StatusIconTests {

    @Test func givenRunning_whenPickingASymbol_thenThereIsNoneBecauseASpinnerIsDrawn() {
        // given / when / then
        #expect(StatusIcon.symbolName(for: .running) == nil)
    }

    @Test func givenEachTerminalStatus_whenPickingASymbol_thenMatchesTheSharedBadgeSemantics() {
        // given / when / then — the same symbol vocabulary as the StatusBadge (SPEC §5.1), in the
        // plain glyphs with no disc: a filled stop for cancelled.
        #expect(StatusIcon.symbolName(for: .completed) == "checkmark")
        #expect(StatusIcon.symbolName(for: .failed) == "xmark")
        #expect(StatusIcon.symbolName(for: .timedOut) == "xmark")
        #expect(StatusIcon.symbolName(for: .cancelled) == "stop.fill")
    }

    @Test func givenPendingAndQueuedRawStatuses_whenPickingASymbol_thenACircleIsUsed() {
        // given / when / then
        #expect(StatusIcon.symbolName(for: .other("pending")) == "circle")
        #expect(StatusIcon.symbolName(for: .other("queued")) == "circle")
    }
}

@Suite struct BackendDotStackTests {

    @Test func givenSeveralBackends_whenBuildingTheAccessibilityText_thenItListsThemCapitalised() {
        // given / when
        let text = BackendDotStack.accessibilityText(for: ["claude", "codex", "vibe"])

        // then
        #expect(text == "Claude, Codex, Vibe")
    }

    @Test func givenRepeatedBackends_whenBuildingTheAccessibilityText_thenEachAppearsOnce() {
        // given / when / then
        #expect(BackendDotStack.accessibilityText(for: ["vibe", "vibe", "codex"]) == "Vibe, Codex")
    }
}
