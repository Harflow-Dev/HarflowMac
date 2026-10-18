@testable import MainWindowFeature
import Testing

// MARK: - WorkflowNodeOutlineTests

struct WorkflowNodeOutlineTests {
    @Test(arguments: [false, true])
    func givenRunningNode_whenSelectedOrUnselected_thenExecutionRemainsIndependent(_ selected: Bool) {
        // given / when
        let outline = WorkflowNodeOutline(status: "running", isSelected: selected)
        // then
        #expect(outline.isExecuting)
        #expect(outline.isEmphasized)
    }

    @Test(arguments: ["reserved", "pending", "completed", "failed", "not_selected"])
    func givenNonRunningNode_whenSelected_thenSelectionIsStatic(_ status: String) {
        // given / when
        let outline = WorkflowNodeOutline(status: status, isSelected: true)
        // then
        #expect(!outline.isExecuting)
        #expect(outline.isEmphasized)
    }

    @Test func givenRunStops_whenPresentationChanges_thenExecutionOutlineEnds() {
        // given
        let running = WorkflowNodeOutline(status: "running", isSelected: false)
        // when
        let completed = WorkflowNodeOutline(status: "completed", isSelected: false)
        // then
        #expect(running.isExecuting)
        #expect(!completed.isExecuting)
        #expect(!completed.isEmphasized)
        #expect(WorkflowNodeOutline(status: "reserved", isSelected: false).isEmphasized)
    }
}
