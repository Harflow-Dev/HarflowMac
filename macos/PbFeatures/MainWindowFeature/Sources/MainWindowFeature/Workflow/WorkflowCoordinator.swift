import Foundation
import MonitorCore
import PbCommon
import PbUtilities
import SwiftUI

// MARK: - Workflow coordinator integration

public extension MainWindowNavigationCoordinator {
    /// Lightweight coordinators do not mount the workflow launcher.
    var isWorkflowRunnerPresented: Bool {
        get { false }
        set { _ = newValue }
    }

    /// Preview coordinators may ignore launcher presentation.
    func presentWorkflowRunner() {}
    /// Empty launcher content for preview coordinators.
    func buildWorkflowRunnerView() -> AnyView { EmptyView().eraseToAnyView() }

    /// Safe default for lightweight preview/test coordinators that do not mount workflows.
    func buildWorkflowEditorView(name _: String?) -> AnyView { Text("Workflow editor").eraseToAnyView() }
    /// Default for preview/test coordinators without a run monitor.
    func buildWorkflowRunView(id _: String) -> AnyView { buildWorkflowEditorView(name: nil) }
}

extension MainWindowCoordinator: WorkflowRouting {
    public func buildWorkflowRunnerView() -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel,
                            draftStore: WorkflowRunnerDraftStore(), routesStartedRun: true)
        return WorkflowRunnerView(vm).eraseToAnyView()
    }

    public func buildWorkflowEditorView(name: String?) -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel, draftStore: WorkflowDraftStore.applicationStore())
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

    func openWorkflowRun(id: String) {
        isWorkflowRunnerPresented = false
        handle(path: MonitorDestination.workflowRun(id))
    }

    func openWorkflowEditor(name: String?) {
        selection = name.map { .workflow($0) } ?? .newWorkflow(UUID())
    }

    public func buildWorkflowRunView(id: String) -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel, draftStore: WorkflowDraftStore.applicationStore())
        vm.prepareRun(id: id, polling: workflowRunPolling)
        return WorkflowView(vm, builderTaskView: buildWorkflowBuilderTaskView).id("workflow-run:\(id)").eraseToAnyView()
    }
}
