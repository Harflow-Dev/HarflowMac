@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowCanvasDropPolicyTests

@Suite struct WorkflowCanvasDropPolicyTests {
    @Test(arguments: WorkflowRole.palette)
    func givenPaletteRole_whenDroppedOnEditableCanvas_thenAcceptsRole(_ role: String) {
        // given / when / then
        #expect(WorkflowCanvasDropPolicy.accepts(role, isEditable: true, nodes: []))
    }

    @Test func givenReadOnlyCanvasOrUnknownRole_whenDropped_thenRejectsPayload() {
        // given / when / then
        #expect(!WorkflowCanvasDropPolicy.accepts("workflow", isEditable: false, nodes: []))
        #expect(!WorkflowCanvasDropPolicy.accepts("unknown", isEditable: true, nodes: []))
    }

    @Test(arguments: ["start", "end"])
    func givenExistingBoundary_whenDroppedAgain_thenRejectsDuplicate(_ role: String) {
        // given
        let node = WorkflowNodeModel(raw: ["type": .string(role)])
        // when / then
        #expect(!WorkflowCanvasDropPolicy.accepts(role, isEditable: true, nodes: [node]))
        #expect(WorkflowCanvasDropPolicy.accepts("workflow", isEditable: true, nodes: [node]))
    }
}
