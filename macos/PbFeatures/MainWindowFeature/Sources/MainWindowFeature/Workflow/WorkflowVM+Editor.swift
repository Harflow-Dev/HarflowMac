import Foundation
import MonitorCore

// MARK: - WorkflowVM editor lifecycle

extension WorkflowVM {
    func selectWorkflow(_ workflow: WorkflowRecord) {
        persistDraft()
        draftKey = "saved:" + workflow.id
        if restoreDraft() { return }
        draftPersistenceSuspended = true
        draftID = UUID()
        let loadingDraftID = draftID
        editorLoadID = UUID()
        let loadingID = editorLoadID
        let loadingDefinition = definition
        let loadingName = name
        perform { [weak self] in
            guard let self else {
                return
            }
            guard draftID == loadingDraftID, editorLoadID == loadingID else { return }
            var loaded = false
            defer {
                if editorLoadID == loadingID {
                    draftPersistenceSuspended = false
                    if !loaded { draftKey = nil }
                }
            }
            let response = try await useCase.command("get", options: [], positionals: [workflow.id])
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

    func selectRun(_ run: WorkflowRunModel) {
        persistDraft()
        draftID = UUID()
        selectedRun = run
        isEditing = false
        selectedNodeID = nil
        selectedEdgeID = nil
        selectedActivationID = nil
        perform { [weak self] in await self?.refresh() }
    }

    func newWorkflow() {
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
        if let name { draftPersistenceSuspended = true; self.name = name; isEditing = true; draftPersistenceSuspended = false } else { newWorkflow() }
    }

    func reloadEditorAfterLateSave(name: String) {
        draftKey = nil
        pendingEditorName = name
    }

    func openWorkflowEditor(_ name: String) { routing.openWorkflowEditor(name: name) }

}
