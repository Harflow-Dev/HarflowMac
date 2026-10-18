#if DEBUG
import Foundation
import MonitorCore
import PbRepository
import PbUI
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
            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)),
            visibility: NullMonitorVisibility(),
            scheduler: NullScheduling()
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

    static func synchronizeRun(_ vm: WorkflowVM) {
        (vm.useCase as? PreviewWorkflowUseCase)?.run = vm.selectedRun?.raw ?? [:]
    }

    /// A run with a long input question, for the recovery banner's wrapping and the
    /// diagnostics viewport's scroll fallback. Dummy preview data only.
    static func makeLongQuestionRun() -> WorkflowVM {
        let vm = make(run: true)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["input_question"] = .string(
            "The review step rejected the latest attempt because the public API of TokenStore changed, "
                + "which the original request explicitly forbids. Decide whether to instruct the implementation "
                + "step to restore the previous signature or to accept the new API and update the call sites."
        )
        vm.selectedRun = WorkflowRunModel(raw: raw)
        return vm
    }

    /// A populated child run for the side panel: parent/root/owner links, a child-workflow
    /// invocation with its assigned request, a technical plan, and a selected node — the
    /// side panel's every disclosure has real dummy content. Preview data only.
    static func makePopulatedChildRun() -> WorkflowVM {
        let vm = make(run: true)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["parent_workflow_run_id"] = .string("preview-parent-run")
        raw["root_workflow_run_id"] = .string("preview-root-run")
        raw["orchestrator_session_owner_run_id"] = .string("preview-owner-run")
        raw["prompt"] = .string("Prepare the release: update the version, run the suite, and draft the changelog.")
        raw["technical_plan"] = .string("1. Bump the version constant.\n2. Run the regression suite.\n3. Draft the changelog entry.")
        raw["repo_path"] = .string("/tmp/OrbitDesk")
        raw["created_at"] = .number(1_700_000_000)
        raw["activations"] = .array([
            .object([
                "id": .string("preview-invocation"),
                "role": .string("node"),
                "node_id": .string("implementation"),
                "status": .string("completed"),
                "invocation": .object([
                    "child_workflow_run_id": .string("preview-child-run"),
                    "workflow_name": .string("Review")
                ])
            ]),
            .object([
                "id": .string("preview-decision"),
                "role": .string("orchestrator"),
                "node_id": .string("implementation"),
                "status": .string("completed"),
                "reason": .string("Proceed to the review step after the implementation reported its task IDs.")
            ])
        ])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = vm.nodes.first { $0.type == "agent" }?.id
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

    func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] { [:] }
}

@MainActor
private struct PreviewWorkflowRouting: WorkflowRouting {
    func chooseDirectory() async -> String? { nil }
    func selectTask(_: String) {}
    func didSaveWorkflow(name _: String) {}
    func openWorkflowEditor(name _: String?) {}
    func openWorkflowRun(id _: String) {}
}

// MARK: - Workflow previews

#Preview("Workflow editor - light") {
    WorkflowView(WorkflowPreview.make())
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow editor - dark") {
    WorkflowView(WorkflowPreview.make())
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Workflow editor - narrow") {
    WorkflowView(WorkflowPreview.make())
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
}

#Preview("Workflow editor - unsaved changes") {
    let vm = WorkflowPreview.make()
    vm.updateNode("start", key: "title", value: .string("kickoff"))
    return WorkflowView(vm)
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow run - light") {
    WorkflowView(WorkflowPreview.make(run: true))
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow run - dark") {
    WorkflowView(WorkflowPreview.make(run: true))
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Workflow run - populated child sidebar") {
    WorkflowView(WorkflowPreview.makePopulatedChildRun())
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Workflow run - long question") {
    WorkflowView(WorkflowPreview.makeLongQuestionRun())
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Workflow run - reduced motion") {
    WorkflowView(WorkflowPreview.make(run: true))
        .frame(width: PbRadius.Metrics.workflowPreviewWidth, height: PbRadius.Metrics.workflowPreviewHeight)
        .environment(\.pbReduceMotionOverride, true)
}
#endif
