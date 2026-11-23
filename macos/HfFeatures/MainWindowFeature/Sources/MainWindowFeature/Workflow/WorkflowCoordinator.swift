import Foundation
import HfCommon
import HfRepository
import HfUtilities
import MonitorCore
import SwiftEnvironment
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

    /// Lightweight preview coordinators may omit library content.
    func buildWorkflowLibraryView() -> AnyView { EmptyView().eraseToAnyView() }

    /// Safe default for lightweight preview/test coordinators that do not mount workflows.
    func buildWorkflowEditorView(name _: String?) -> AnyView { Text("Workflow editor").eraseToAnyView() }
    /// Default for preview/test coordinators without a run monitor.
    func buildWorkflowRunView(id _: String) -> AnyView { buildWorkflowEditorView(name: nil) }
}

extension MainWindowCoordinator: WorkflowRouting, WorkflowLibraryRouting {
    func openWorkflowRunner(name: String?) {
        guard workIsAvailable else { return }
        initialWorkflowRunnerName = name
        isWorkflowRunnerPresented = true
    }

    public func presentWorkflowRunner() { openWorkflowRunner(name: nil) }

    public func buildWorkflowLibraryView() -> AnyView {
        WorkflowLibraryView(WorkflowLibraryVM(useCase: WorkflowLibraryViewRepository(), routing: self,
                                             visibility: GlobalValues.monitorVisibility, scheduler: GlobalValues.scheduling)).eraseToAnyView()
    }

    func editLibraryWorkflow(name: String) { openWorkflowEditor(name: name) }
    func runLibraryWorkflow(name: String) { openWorkflowRunner(name: name) }
    func newLibraryWorkflow(generate: Bool) {
        let identity = UUID()
        workflowGenerationIntent = generate ? identity : nil
        selection = .newWorkflow(identity)
    }

    public func buildWorkflowRunnerView() -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self)
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel,
                            draftStore: WorkflowRunnerDraftStore(), routesStartedRun: true,
                            visibility: GlobalValues.monitorVisibility, scheduler: GlobalValues.scheduling)
        return WorkflowRunnerView(vm, initialName: initialWorkflowRunnerName).eraseToAnyView()
    }

    public func buildWorkflowEditorView(name: String?) -> AnyView {
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self,
                                  horizontalPosition: parallelPosition(for: "workflow:" + (name ?? "new")))
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel,
                            draftStore: WorkflowDraftStore.applicationStore(),
                            visibility: GlobalValues.monitorVisibility, scheduler: GlobalValues.scheduling)
        vm.prepareEditor(name: name)
        if name == nil, case let .newWorkflow(identity) = selection, workflowGenerationIntent == identity {
            vm.showsGenerateSheet = true
        }
        return WorkflowView(vm, builderTaskView: buildWorkflowBuilderTaskView).id(workflowEditorMountIdentity(name: name)).eraseToAnyView()
    }

    func workflowEditorMountIdentity(name: String?) -> String {
        if let name { return name }
        if case let .newWorkflow(identity) = selection { return identity.uuidString }
        return "new-workflow"
    }

    private func buildWorkflowBuilderTaskView(taskID: String, runID: String) -> AnyView {
        let useCase = TaskDetailViewRepository(builderRunID: runID)
        let vm = TaskDetailVM(taskID: taskID, useCase: useCase, routing: self, continuityHistory: continuityHistory,
                              chrome: .builder, scheduler: GlobalValues.scheduling, isWorkflowBuilder: true)
        let conversationID = useCase.conversationMembers(of: taskID).first?.id ?? taskID
        return TaskDetailView(vm, chrome: .builder, transcriptStyle: .transcript).id(conversationID).eraseToAnyView()
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
        let parallel = ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: self,
                                  horizontalPosition: parallelPosition(for: "workflow-run:" + id))
        let vm = WorkflowVM(useCase: WorkflowViewRepository(), routing: self, parallel: parallel,
                            draftStore: WorkflowDraftStore.applicationStore(),
                            visibility: GlobalValues.monitorVisibility, scheduler: GlobalValues.scheduling)
        vm.prepareRun(id: id, polling: workflowRunPolling)
        return WorkflowView(vm, builderTaskView: buildWorkflowBuilderTaskView).id("workflow-run:\(id)").eraseToAnyView()
    }
}
