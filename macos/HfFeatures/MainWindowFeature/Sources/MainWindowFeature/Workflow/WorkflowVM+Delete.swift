import Foundation
import HfCommon
import HfRepository
import MonitorCore

// MARK: - WorkflowDeleteContext

/// Local editor fencing only: the public delete command is name-only, without compare-and-swap.
struct WorkflowDeleteContext {
    let editor: WorkflowDiscardContext
    let loadingID: UUID
    let runtime: QualificationRuntimeToken
    let completion: WorkflowDraftCompletion?

    @MainActor init(_ vm: WorkflowVM, runtime: QualificationRuntimeToken) {
        self.editor = WorkflowDiscardContext(vm)
        self.loadingID = vm.initialLoadingID
        self.runtime = runtime
        self.completion = WorkflowDraftCompletion.completed[vm.draftID]
    }

    @MainActor func matches(_ vm: WorkflowVM) -> Bool {
        let current = WorkflowDraftCompletion.completed[editor.draftID]
        return editor.matches(vm) && loadingID == vm.initialLoadingID
            && (try? vm.useCase.activityRuntime()) == runtime
            && completion?.name == current?.name && completion?.revision == current?.revision
            && completion?.submitted == current?.submitted && completion?.saved == current?.saved
    }
}

// MARK: - WorkflowDeleteFailure

struct WorkflowDeleteFailure {
    let context: WorkflowDeleteContext
    let reason: String
}

// MARK: - WorkflowVM Delete

extension WorkflowVM {
    var deleteFailureText: String? {
        guard let deleteFailure, deleteFailure.context.matches(self) else { return nil }
        return deleteFailure.reason
    }

    var canDeleteWorkflow: Bool {
        isEditing && !loadedName.isEmpty && !isBusy && canEditHistory && !checkingEditorBaseline
            && builderSession == nil && !builderDispatchPending && !draftPersistenceSuspended
            && (try? useCase.activityRuntime()) != nil
    }

    func deleteWorkflow() {
        guard canDeleteWorkflow, let runtime = try? useCase.activityRuntime() else { return }
        let context = WorkflowDeleteContext(self, runtime: runtime)
        let requestID = UUID()
        deleteRequestID = requestID
        deleteFailure = nil
        let dirty = name != loadedName || !WorkflowDraftEquality.matches(definition, savedDefinition)
        let description = "Existing run snapshots remain available." + (dirty ? "\nUnsaved changes will be lost." : "")
        publishDialog("Delete workflow ‘\(context.editor.loadedName)’?", description: description) {
            AlertAction(title: "Cancel", role: .cancel, isDefault: true) { [weak self] in
                guard self?.deleteRequestID == requestID else { return }
                self?.deleteRequestID = nil
            }
            AlertAction(title: "Delete", role: .destructive) { [weak self] in
                self?.confirmDelete(requestID: requestID, context: context)
            }
        }
    }

    private func confirmDelete(requestID: UUID, context: WorkflowDeleteContext) {
        guard deleteRequestID == requestID else { return }
        deleteRequestID = nil
        guard canDeleteWorkflow, context.matches(self) else { return }
        perform { [weak self] in
            guard let self, context.matches(self) else { return }
            do {
                let response = try await useCase.command("delete", options: [], positionals: [context.editor.loadedName], runtime: context.runtime)
                guard context.matches(self) else { return }
                guard response["deleted"]?.stringValue == context.editor.loadedName else {
                    let reason = "Deletion could not be confirmed. The workflow may already be deleted. Refresh before trying again."
                    deleteFailure = WorkflowDeleteFailure(context: context, reason: reason)
                    return
                }
                routing.openWorkflowEditor(name: nil)
            } catch {
                guard context.matches(self) else { return }
                deleteFailure = WorkflowDeleteFailure(context: context, reason: Self.message(error))
            }
        }
    }
}
