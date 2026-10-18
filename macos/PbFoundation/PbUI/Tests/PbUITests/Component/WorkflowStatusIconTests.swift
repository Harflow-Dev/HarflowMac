import MonitorCore
@testable import PbUI
import Testing

// MARK: - WorkflowStatusIconTests

struct WorkflowStatusIconTests {
    @Test func givenWorkflowSettlingOrInputStatus_whenChoosingIndicator_thenSpinnerOrAttentionSymbolIsUsed() {
        // given / when / then — settling draws a spinner; attention is a triangle (SPEC §5.1),
        // pending a circle, and an unknown raw status keeps the honest dashed circle.
        #expect(StatusIcon.symbolName(for: .other("Settling")) == nil)
        #expect(StatusIcon.symbolName(for: .other("Needs input")) == "exclamationmark.triangle.fill")
        #expect(StatusIcon.symbolName(for: .other("needs_attention")) == "exclamationmark.triangle.fill")
        #expect(StatusIcon.symbolName(for: .other("pending")) == "circle")
        #expect(StatusIcon.symbolName(for: .other("Queued")) == "circle")
        #expect(StatusIcon.symbolName(for: .other("unknown")) == "circle.dashed")
    }
}
