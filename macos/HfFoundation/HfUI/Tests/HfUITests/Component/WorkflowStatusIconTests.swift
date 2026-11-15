@testable import HfUI
import MonitorCore
import Testing

// MARK: - WorkflowStatusIconTests

struct WorkflowStatusIconTests {
    @Test func givenWorkflowSettlingOrInputStatus_whenChoosingIndicator_thenSpinnerOrAttentionSymbolIsUsed() {
        // given / when / then — settling draws a spinner; attention is the raised hand,
        // pending a circle, and an unknown raw status keeps the honest dashed circle.
        #expect(StatusIcon.symbolName(for: .other("Settling")) == nil)
        #expect(StatusIcon.symbolName(for: .other("Needs input")) == nil)
        #expect(StatusIcon.glyph(for: .other("Needs input")) == .shape(.hand))
        #expect(StatusIcon.glyph(for: .other("needs_attention")) == .shape(.hand))
        #expect(StatusIcon.symbolName(for: .other("pending")) == "circle")
        #expect(StatusIcon.symbolName(for: .other("Queued")) == "circle")
        #expect(StatusIcon.symbolName(for: .other("unknown")) == "circle.dashed")
    }
}
