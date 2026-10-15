import Foundation
import MonitorCore
import PbCommon

// MARK: - WorkflowVM conflict recovery

extension WorkflowVM {
    func checkEditorBaseline(_ workflow: WorkflowRecord, retainConflict: Bool = false) {
        let identity = draftID
        let loadID = editorLoadID
        checkingEditorBaseline = true
        editorReadTask = Task { [weak self] in
            guard let self else { return }
            defer { if draftID == identity, editorLoadID == loadID { checkingEditorBaseline = false } }
            do {
                let response = try await useCase.command("get", options: [], positionals: [workflow.id])
                guard !Task.isCancelled, draftID == identity, editorLoadID == loadID else { return }
                let record = WorkflowRecord(raw: response["workflow"]?.objectValue ?? response)
                if !baselineMatches(record) {
                    editorConflict = "The saved workflow changed or was replaced. Your unsaved draft is preserved. "
                        + "Save a copy and reload to reconcile it with the current version."
                } else if !retainConflict { editorConflict = nil }
            } catch {
                guard !Task.isCancelled, draftID == identity, editorLoadID == loadID else { return }
                editorConflict = "The current saved workflow could not be read. It may have been deleted. "
                    + "Your unsaved draft is preserved. " + Self.message(error)
            }
        }
    }

    func baselineMatches(_ record: WorkflowRecord) -> Bool {
        record.id == loadedName && record.revision == revision
            && record.workflowID == (savedDefinition["workflow_id"]?.stringValue ?? "")
            && record.definition == savedDefinition
    }

    func preserveDraftAndReload() {
        guard selectedRun == nil, builderSession == nil, !builderDispatchPending, !loadedName.isEmpty, !isBusy, !checkingEditorBaseline,
              canUseDraftSlot("new"), persistDraft() else { return }
        let target = loadedName
        let previousKey = draftKey
        duplicate()
        guard draftKey == "new", persistDraft(), draftKey == "new" else { return }
        do {
            // The copy is durable before the old slot is removed or the saved version is read.
            guard try draftStore.load(key: "new")?["draft_id"]?.stringValue == draftID.uuidString else { return }
            if let previousKey { try draftStore.remove(key: previousKey) }
        } catch {
            errorText = "Your copy is preserved, but the old draft could not be removed: " + Self.message(error)
            return
        }
        selectWorkflow(WorkflowRecord(raw: ["name": .string(target)]))
    }

    func replaceMissingReferences(_ target: String, with replacement: String) {
        guard selectedRun == nil, !target.isEmpty, target != replacement,
              let record = workflows.first(where: { $0.workflowID == replacement }),
              !workflows.contains(where: { $0.workflowID == target }) else { return }
        let affected = nodes.filter { $0.type == "workflow" && $0.workflowID == target }
        guard !affected.isEmpty else { return }
        let snapshot = definition
        let identity = draftID
        publishDialog("Replace unavailable workflow in \(affected.count) steps?",
                      description: affected.map { "\($0.name) (\($0.id))" }.joined(separator: "\n")
                          + "\n\nUse ‘\(record.id)’ in these steps of this workflow only.") {
            AlertAction(title: "Replace all") { [weak self] in
                guard let self, selectedRun == nil, draftID == identity, definition == snapshot else { return }
                var updated = snapshot
                updated["nodes"] = .array(WorkflowJSON.objects(snapshot["nodes"]).map { node in
                    guard node["type"]?.stringValue == "workflow", node["workflow_ref"]?["workflow_id"]?.stringValue == target else { return .object(node) }
                    var node = node
                    node["workflow_ref"] = .object(["workflow_id": .string(replacement)])
                    node["workflow_name"] = .string(record.id)
                    return .object(node)
                })
                definition = updated
            }
        }
    }
}
