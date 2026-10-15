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

    func discardChanges() {
        guard canDiscard else { return }
        guard builderSession == nil, !builderDispatchPending else { return }
        guard !loadedName.isEmpty else { discardChanges(using: nil); return }
        let identity = draftID
        let loadID = editorLoadID
        let snapshot = definition
        let originalName = name
        let target = loadedName
        perform { [weak self] in
            guard let self else { return }
            let response = try await useCase.command("get", options: [], positionals: [target])
            guard draftID == identity, editorLoadID == loadID, definition == snapshot, name == originalName,
                  builderSession == nil, !builderDispatchPending else { return }
            let current = WorkflowRecord(raw: response["workflow"]?.objectValue ?? response)
            guard !current.id.isEmpty, !current.definition.isEmpty else { return }
            discardChanges(using: current)
        }
    }

    private func discardChanges(using current: WorkflowRecord?) {
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
        // Adopt a save that completed in another editor before choosing the baseline.
        guard persistDraft(reconnectBuilder: false) else { return }
        reconnectBuilderSession()
        guard builderSession == nil, !builderDispatchPending else { return }
        do {
            if let key = draftKey, let draft = try draftStore.load(key: key) {
                guard draft["draft_id"]?.stringValue == draftID.uuidString,
                      draft["builder_session"] == nil, draft["builder_dispatch_pending"]?.boolValue != true else {
                    errorText = "The workflow draft changed in another editor. Reopen it before discarding changes."
                    return
                }
                try draftStore.remove(key: key)
            }
        } catch {
            errorText = "Unable to discard workflow draft: \(Self.message(error))"
            return
        }
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

    private func pruneEditorSelection() {
        let edge = selectedEdgeID
        selectNodes(selectedNodeIDs, primary: selectedNodeID)
        selectedEdgeID = edge.flatMap { id in edges.contains(where: { $0.id == id }) ? id : nil }
        connectionSourceID = nil
    }
}
