#if DEBUG
import Foundation
import MonitorCore
import PbRepository
import PbUtilities
import SwiftUI

// MARK: - WorkflowPreview

@MainActor
enum WorkflowPreview {
    static func make(run: Bool = false) -> WorkflowVM {
        let routing = PreviewWorkflowRouting()
        let useCase = PreviewWorkflowUseCase()
        let vm = WorkflowVM(
            useCase: useCase,
            routing: routing,
            parallel: ParallelVM(groupName: "Workflow", useCase: ParallelViewRepository(), routing: routing),
            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        )
        vm.newWorkflow()
        vm.name = "code-review"
        vm.loadedName = "code-review"
        vm.savedDefinition = vm.definition
        vm.selectedNodeID = nil
        if run {
            vm.selectedRun = WorkflowRunModel(raw: [
                "workflow_run_id": .string("preview-run"),
                "name": .string("code-review"),
                "status": .string("needs_attention"),
                "attention_reason": .string("Implementation reached its attempt limit."),
                "definition": .object(vm.definition),
                "tasks": .array([
                    .object([
                        "id": .string("tests"),
                        "title": .string("Add regression coverage"),
                        "status": .string("completed"),
                        "reason": .string("Orchestrator confirmed the successful test result.")
                    ]),
                    .object(["id": .string("fix"), "title": .string("Implement the change"), "status": .string("pending")])
                ])
            ])
            useCase.run = vm.selectedRun?.raw ?? [:]
        }
        return vm
    }
}

@MainActor
private final class PreviewWorkflowUseCase: WorkflowUseCase, @unchecked Sendable {
    var run: [String: JSONValue] = [:]
    var backendIDs: [String] { ["codex", "claude", "vibe"] }
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
    func refreshTasks() async {}
    func command(_ command: String, options _: [String], positionals _: [String]) async throws -> [String: JSONValue] {
        command == "status" ? run : [:]
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }

    func save(name _: String, definition _: JSONValue, expectedRevision _: Int) async throws -> [String: JSONValue] { [:] }
}

@MainActor
private struct PreviewWorkflowRouting: WorkflowRouting {
    func chooseDirectory() async -> String? { nil }
    func selectTask(_: String) {}
    func didSaveWorkflow(name _: String) {}
    func openWorkflowEditor(name _: String?) {}
    func openWorkflowRun(id _: String) {}
}

#Preview("Workflow editor") { WorkflowView(WorkflowPreview.make()).frame(width: 1200, height: 700) }
#Preview("Workflow run") { WorkflowView(WorkflowPreview.make(run: true)).frame(width: 1200, height: 700) }
#endif
