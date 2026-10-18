import MonitorCore
@testable import PbUI
import Testing

@Suite struct StatusIconTests {

    @Test func givenRunning_whenPickingASymbol_thenThereIsNoneBecauseASpinnerIsDrawn() {
        // given / when / then
        #expect(StatusIcon.symbolName(for: .running) == nil)
    }

    @Test func givenEachTerminalStatus_whenPickingASymbol_thenMatchesTheSharedBadgeSemantics() {
        // given / when / then — the same symbol vocabulary as the StatusBadge (SPEC §5.1), in the
        // icon's filled-circle family: a stop glyph for cancelled.
        #expect(StatusIcon.symbolName(for: .completed) == "checkmark.circle.fill")
        #expect(StatusIcon.symbolName(for: .failed) == "xmark.circle.fill")
        #expect(StatusIcon.symbolName(for: .timedOut) == "xmark.circle.fill")
        #expect(StatusIcon.symbolName(for: .cancelled) == "stop.circle.fill")
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
