import Foundation
import MonitorCore

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
                response = try await useCase.command("get", options: [], positionals: [workflow.id])
            } catch {
                guard draftID == loadingDraftID, editorLoadID == loadingID, !Task.isCancelled else { return }
                errorText = Self.message(error)
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
            draftPersistenceSuspended = false
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

    func openWorkflowEditor(_ name: String) { routing.openWorkflowEditor(name: name) }

}
