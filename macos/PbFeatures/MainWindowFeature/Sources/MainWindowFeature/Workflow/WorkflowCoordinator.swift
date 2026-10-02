import Foundation
import MonitorCore
import PbCommon
import PbUtilities
import SwiftUI

// MARK: - Workflow coordinator integration

public extension MainWindowNavigationCoordinator {
    /// Safe default for lightweight preview/test coordinators that do not mount workflows.
    func buildWorkflowEditorView(name _: String?) -> AnyView { Text("Workflow editor").eraseToAnyView() }
    /// Default for preview/test coordinators without a run monitor.
    func buildWorkflowRunView(id _: String) -> AnyView { buildWorkflowEditorView(name: nil) }
}

extension MainWindowCoordinator: WorkflowRouting {
    public func buildWorkflowEditorView(name: String?) -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel)
        vm.prepareEditor(name: name)
        return WorkflowView(vm, builderTaskView: buildWorkflowBuilderTaskView).id(name ?? "new-workflow").eraseToAnyView()
    }

    private func buildWorkflowBuilderTaskView(taskID: String, runID: String) -> AnyView {
        let useCase = TaskDetailViewRepository(builderRunID: runID)
        let vm = TaskDetailVM(taskID: taskID, useCase: useCase, routing: self, isWorkflowBuilder: true)
        let conversationID = useCase.conversationMembers(of: taskID).first?.id ?? taskID
        return TaskDetailView(vm, isEmbedded: true).id(conversationID).eraseToAnyView()
    }

    func didSaveWorkflow(name: String) { selection = .workflow(name) }

    func openWorkflowEditor(name: String?) {
        selection = name.map { .workflow($0) } ?? .newWorkflow(UUID())
    }

    public func buildWorkflowRunView(id: String) -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel)
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(id), "status": .string("starting")])
        return WorkflowView(vm, builderTaskView: buildWorkflowBuilderTaskView).id("workflow-run:\(id)").eraseToAnyView()
    }
}
