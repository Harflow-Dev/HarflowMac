import Foundation
import MonitorCore

// MARK: - WorkflowEditSnapshot

struct WorkflowEditSnapshot: Equatable {
    let name: String
    let definition: [String: JSONValue]
}

// MARK: - WorkflowVM edit history

extension WorkflowVM {
    func recordEdit(name previousName: String, definition previousDefinition: [String: JSONValue]) {
        guard isEditing, selectedRun == nil, !draftPersistenceSuspended, !editHistorySuspended, nodeDragSnapshot == nil else { return }
        let previous = WorkflowEditSnapshot(name: previousName, definition: previousDefinition)
        guard previous != WorkflowEditSnapshot(name: name, definition: definition) else { return }
        editHistory.append(previous)
        trimEditHistory()
    }

    private func trimEditHistory() {
        if editHistory.count > 100 { editHistory.removeFirst(editHistory.count - 100) }
    }

    func resetEditHistory() {
        editHistory.removeAll()
        nodeDragSnapshot = nil
    }

    func beginNodeDrag() {
        guard canEditHistory, nodeDragSnapshot == nil else { return }
        nodeDragSnapshot = WorkflowEditSnapshot(name: name, definition: definition)
    }

    func endNodeDrag() {
        guard let snapshot = nodeDragSnapshot else { return }
        nodeDragSnapshot = nil
        if snapshot != WorkflowEditSnapshot(name: name, definition: definition) { editHistory.append(snapshot); trimEditHistory() }
    }

    func undoWorkflowEdit() {
        endNodeDrag()
        reconnectBuilderSession()
        guard canUndo, let snapshot = editHistory.popLast() else { return }
        editHistorySuspended = true
        name = snapshot.name
        definition = snapshot.definition
        editHistorySuspended = false
        pruneEditorSelection()
        persistDraft()
    }

    func discardChanges(using current: WorkflowRecord?, isCurrent: () -> Bool = { true }) {
        guard isCurrent() else { return }
        endNodeDrag()
        guard builderSession == nil, !builderDispatchPending else { return }
        do {
            if let key = draftKey, let draft = try draftStore.load(key: key),
               draft["draft_id"]?.stringValue != draftID.uuidString {
                errorText = "The workflow draft belongs to another editor. Reopen it before discarding changes."
                return
            }
        } catch {
            errorText = "Unable to inspect workflow draft: \(Self.message(error))"
            return
        }
        reconnectBuilderSession()
        guard builderSession == nil, !builderDispatchPending else { return }
        guard isCurrent() else { return }
        // Saved discard must reject a late completion before persistence can adopt or delete it.
        guard persistDraft(reconnectBuilder: false) else { return }
        reconnectBuilderSession()
        guard builderSession == nil, !builderDispatchPending, isCurrent() else { return }
        guard removeDiscardedDraft(isCurrent: isCurrent) else { return }
        draftWriteTask?.cancel()
        draftWriteTask = nil
        draftPersistenceSuspended = true
        editorReadTask?.cancel()
        checkingEditorBaseline = false
        draftID = UUID()
        editorLoadID = UUID()
        editorConflict = nil
        if let current {
            loadedName = current.id
            revision = current.revision
            savedDefinition = current.definition
        }
        name = loadedName
        definition = loadedName.isEmpty ? Self.starterDefinition() : savedDefinition
        draftPersistenceSuspended = false
        resetEditHistory()
        pruneEditorSelection()
        errorText = nil
    }

    private func removeDiscardedDraft(isCurrent: () -> Bool) -> Bool {
        do {
            if let key = draftKey, let draft = try draftStore.load(key: key) {
                guard draft["draft_id"]?.stringValue == draftID.uuidString,
                      draft["builder_session"] == nil, draft["builder_dispatch_pending"]?.boolValue != true else {
                    errorText = "The workflow draft changed in another editor. Reopen it before discarding changes."
                    return false
                }
                guard isCurrent() else { return false }
                try draftStore.remove(key: key)
            }
        } catch {
            errorText = "Unable to discard workflow draft: \(Self.message(error))"
            return false
        }
        return true
    }

    private func pruneEditorSelection() {
        if isOrchestratorSelected || selectedOnDemandNode != nil { return }
        let edge = selectedEdgeID
        selectNodes(selectedNodeIDs, primary: selectedNodeID)
        selectedEdgeID = edge.flatMap { id in edges.contains(where: { $0.id == id }) ? id : nil }
        connectionSourceID = nil
    }
}
