import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - SidebarVMTests selection ordering

@MainActor
extension SidebarVMTests {
    @Test func givenAnOlderQueuedSelection_whenAnotherRowIsTapped_thenSelectionDoesNotRevert() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        await sut.waitForPresentation()
        harness.selectionSubject.send(.task("previous"))

        // when
        sut.didSelect(.task("current"))
        await sut.waitForPresentation()
        #expect(sut.selection == .task("current"))
        var queueDrained = false
        DispatchQueue.main.async { queueDrained = true }
        await waitUntil { queueDrained }

        // then
        #expect(sut.selection == .task("current"))
    }

    @Test func givenCollapsedWorkflowTree_whenChildSelectedExternally_thenAncestorsRevealWithoutExpandingChild() async {
        // given
        let harness = makeSUT()
        harness.sut.workflowRuns = [
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("root"), "status": .string("running")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("child"), "parent_workflow_run_id": .string("root"), "status": .string("running")]),
            SidebarWorkflowRun(raw: ["workflow_run_id": .string("grandchild"), "parent_workflow_run_id": .string("child"), "status": .string("running")])
        ]
        harness.sut.didAppear()
        await harness.sut.waitForPresentation()
        #expect(!harness.sut.expandedExecutionParents.contains("workflow:root"))
        // when
        harness.selectionSubject.send(.workflowRun("child"))
        await waitUntil { harness.sut.selection == .workflowRun("child") }
        await harness.sut.waitForPresentation()
        // then
        #expect(harness.sut.expandedExecutionParents.contains("workflow:root"))
        #expect(!harness.sut.expandedExecutionParents.contains("workflow:child"))
        #expect(Set(harness.sut.items(in: .running).map(\.id)) == ["workflow:root", "workflow:child", "workflow:grandchild", "workflow-shortcut:root:child"])
        harness.sut.didToggleExpansion(taskID: "workflow:root")
        await harness.sut.waitForPresentation()
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        #expect(!harness.sut.expandedExecutionParents.contains("workflow:root"))
        harness.sut.didDisappear()
    }

}
