import Foundation
@testable import MainWindowFeature
import MonitorCore

// MARK: - QualifiedBuilderFixture

/// A workflow editor bound to a qualified builder runtime, as production mounts it; an unqualified builder run is
/// cleared by `WorkflowVM.validateBuilderRuntime()` when the view appears.
@MainActor enum QualifiedBuilderFixture {
    static func makeVM(name: String) throws -> WorkflowVM {
        let useCase = BuilderSessionUseCase(status: "running")
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowBuilderSessionTests().vm(store: store, useCase: useCase)
        vm.newWorkflow()
        vm.definition = WorkflowPreview.make().definition
        vm.name = name
        vm.loadedName = name
        vm.savedDefinition = vm.definition
        vm.selectedNodeID = nil
        vm.builderRuntime = try useCase.activityRuntime()
        return vm
    }

    static func builderRun(_ vm: WorkflowVM, taskID: String?) -> WorkflowRunModel {
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string("qualified-builder"), "kind": .string("builder"), "name": .string(vm.name),
            "status": .string("running"), "builder_draft": .object(vm.definition)
        ]
        if let taskID {
            raw["activations"] = .array([.object(["role": .string("builder"), "tasks": .array([.object(["task_id": .string(taskID)])])])])
        }
        (vm.useCase as? BuilderSessionUseCase)?.hostedRun = raw
        return WorkflowRunModel(raw: raw)
    }

    static func selectBuilderRun(on vm: WorkflowVM, taskID: String) {
        vm.selectedRun = builderRun(vm, taskID: taskID)
    }
}
