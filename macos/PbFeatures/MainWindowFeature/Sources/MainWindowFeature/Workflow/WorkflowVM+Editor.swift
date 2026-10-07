import Foundation
import MonitorCore
import PbCommon

// MARK: - WorkflowVM editor lifecycle

extension WorkflowVM {
    func selectWorkflow(_ workflow: WorkflowRecord) {
        resetEditHistory()
        editorReadTask?.cancel()
        persistDraft()
        draftKey = "saved:" + workflow.id
        if restoreDraft() { initialLoadingKind = nil; initialLoadFailed = false; return }
        initialLoadingKind = "editor"
        initialLoadFailed = false
        draftPersistenceSuspended = true
        draftID = UUID()
        let loadingDraftID = draftID
        editorLoadID = UUID()
        let loadingID = editorLoadID
        let loadingDefinition = definition
        let loadingName = name
        editorReadTask = Task { [weak self] in
            guard let self else {
                return
            }
            guard draftID == loadingDraftID, editorLoadID == loadingID else { return }
            var loaded = false
            defer {
                if editorLoadID == loadingID {
                    draftPersistenceSuspended = false
                    initialLoadingKind = nil
                    initialLoadFailed = !loaded
                    if !loaded { draftKey = nil }
                }
            }
            let response: [String: JSONValue]
            do {
                response = try await readEditor(workflow, draftID: loadingDraftID, loadID: loadingID)
            } catch {
                guard draftID == loadingDraftID, editorLoadID == loadingID, !Task.isCancelled else { return }
                reportReadFailure(Self.message(error), source: "workflow-editor:" + workflow.id,
                                  retry: editorRetry(workflow, loadID: loadingID))
                return
            }
            guard !Task.isCancelled, draftID == loadingDraftID, editorLoadID == loadingID,
                  definition == loadingDefinition, name == loadingName else { return }
            let record = WorkflowRecord(raw: response["workflow"]?.objectValue ?? response)
            draftPersistenceSuspended = true
            definition = record.definition
            savedDefinition = definition
            name = record.id.isEmpty ? workflow.id : record.id
            loadedName = name
            revision = record.revision
            selectedRun = nil
            selectedNodeID = nil
            selectedEdgeID = nil
            isEditing = true
            parallel.setWorkflowTaskIDs([])
            loaded = true
            resolveReadFailure(source: "workflow-editor:" + workflow.id)
            draftPersistenceSuspended = false
        }
    }

    private func readEditor(_ workflow: WorkflowRecord, draftID: UUID, loadID: UUID) async throws -> [String: JSONValue] {
        while true {
            let response = try await useCase.command("get", options: [], positionals: [workflow.id])
            guard !Task.isCancelled, self.draftID == draftID, editorLoadID == loadID else { throw CancellationError() }
            let state = CatalogState(raw: response)
            switch state.status {
            case .ready: return response
            case .blocked: throw WorkflowReadError.blocked(state.reason ?? "Workflow catalog is blocked.")
            case .preparing: try await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func editorRetry(_ workflow: WorkflowRecord, loadID: UUID) -> AlertAction {
        AlertAction(title: "Reload workflow") { [weak self] in
            guard let self, editorLoadID == loadID else { return }
            selectWorkflow(workflow)
        }
    }

    func prepareRun(id: String, polling: WorkflowRunPolling) {
        runPolling = polling
        selectedRun = WorkflowRunModel(raw: polling.cached(id: id) ?? ["workflow_run_id": .string(id)])
        initialLoadingKind = polling.cached(id: id) == nil ? "run" : nil
    }

    func selectRun(_ run: WorkflowRunModel) {
        resetEditHistory()
        editorReadTask?.cancel()
        editorLoadID = UUID()
        persistDraft()
        draftID = UUID()
        initialLoadingKind = "run"
        initialLoadFailed = false
        selectedRun = run
        isEditing = false
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedActivationID = nil
        perform { [weak self] in await self?.refresh() }
    }

    func newWorkflow() {
        resetEditHistory()
        editorReadTask?.cancel()
        editorLoadID = UUID()
        initialLoadingKind = nil
        initialLoadFailed = false
        persistDraft()
        draftKey = "new"
        if restoreDraft() { return }
        draftPersistenceSuspended = true
        draftID = UUID()
        selectedRun = nil
        name = ""
        loadedName = ""
        revision = 0
        savedDefinition = [:]
        definition = Self.starterDefinition()
        isEditing = true
        selectedNodeID = "start"
        selectedEdgeID = nil
        parallel.setWorkflowTaskIDs([])
        draftPersistenceSuspended = false
        persistDraft()
    }

    func prepareEditor(name: String?) {
        validationSuspended = true
        pendingEditorName = name
        initialLoadingKind = name == nil ? nil : "editor"
        initialLoadFailed = false
        if let name { draftPersistenceSuspended = true; self.name = name; isEditing = true; draftPersistenceSuspended = false } else { newWorkflow() }
    }

    func reloadEditorAfterLateSave(name: String) {
        draftKey = nil
        pendingEditorName = name
    }

    func openRun(_ id: String) { routing.openWorkflowRun(id: id) }

    func openWorkflowEditor(_ name: String) { routing.openWorkflowEditor(name: name) }

}

private enum WorkflowReadError: LocalizedError {
    case blocked(String)
    var errorDescription: String? { if case .blocked(let message) = self { message } else { nil } }
}
