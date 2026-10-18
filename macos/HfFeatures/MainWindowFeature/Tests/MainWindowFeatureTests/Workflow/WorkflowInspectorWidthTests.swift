@testable import MainWindowFeature
import Testing

// MARK: - WorkflowInspectorWidthTests

@Suite struct WorkflowInspectorWidthTests {
    @Test func givenLargeWindow_whenUsingInitialWidth_thenInspectorStartsAt288() {
        // given / when / then — the Phase 3 visual adjustment: the initial ideal width is 288.
        #expect(WorkflowInspectorWidth.initial == 288)
        #expect(WorkflowInspectorWidth.clamped(WorkflowInspectorWidth.initial, available: 1400) == 288)
    }

    @Test func givenResizeRequest_whenClamping_thenInspectorStaysBetween220And500() {
        // given / when / then
        #expect(WorkflowInspectorWidth.clamped(100, available: 1400) == 220)
        #expect(WorkflowInspectorWidth.clamped(700, available: 1400) == 500)
    }

    @Test func givenNarrowWindow_whenClamping_thenCanvasRetainsItsMinimumWidth() {
        // given / when / then
        #expect(WorkflowInspectorWidth.clamped(500, available: 700) == 299)
        #expect(WorkflowInspectorWidth.clamped(280, available: 650) == 249)
    }
}
