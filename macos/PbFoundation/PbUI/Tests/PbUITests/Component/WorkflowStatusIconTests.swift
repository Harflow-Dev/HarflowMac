import MonitorCore
@testable import PbUI
import Testing

// MARK: - WorkflowStatusIconTests

struct WorkflowStatusIconTests {
    @Test func givenWorkflowSettlingOrInputStatus_whenChoosingIndicator_thenSpinnerOrAttentionSymbolIsUsed() {
        // given / when / then
        #expect(StatusIcon.symbolName(for: .other("Settling")) == nil)
        #expect(StatusIcon.symbolName(for: .other("Needs input")) == "exclamationmark.circle")
        #expect(StatusIcon.symbolName(for: .other("needs_attention")) == "exclamationmark.circle")
        #expect(StatusIcon.symbolName(for: .other("unknown")) == "circle.dashed")
    }
}
