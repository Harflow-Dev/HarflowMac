import Foundation
import MonitorCore

// MARK: - WorkflowRefinementContext

struct WorkflowRefinementContext {
    let draftID: UUID
    let loadID: UUID
    let definition: [String: JSONValue]
    let name: String
    let loadedName: String
    let revision: Int
    let baseline: [String: JSONValue]
    var runID: String?
}

// MARK: - WorkflowVM agent editing

extension WorkflowVM {
    var canReturnToCanvas: Bool { refinementContext?.runID == selectedRun?.id && refinementContext != nil }

    func prepareGeneration(refining: Bool) {
        isRefining = refining
        prompt = ""
        showsGenerateSheet = true
    }

    func returnToCanvas() {
        guard canReturnToCanvas else { return }
        selectedRun = nil
        refinementContext = nil
        persistDraft(reconnectBuilder: false)
        isEditing = true
        parallel.setWorkflowTaskIDs([])
    }

    func applyAgentProposal() {
        guard let run = selectedRun, run.status == "completed",
              !appliedProposalIDs.contains(run.id),
              let proposal = run.raw["generated_definition"]?.objectValue,
              run.isBuilderProposal else { return }
        draftPersistenceSuspended = true
        defer { draftPersistenceSuspended = false }
        if let context = refinementContext, context.runID == run.id {
            guard draftID == context.draftID, editorLoadID == context.loadID,
                  definition == context.definition, name == context.name, loadedName == context.loadedName,
                  revision == context.revision, savedDefinition == context.baseline else {
                errorText = "The canvas changed after this request. Return to the canvas to keep your edits; open the proposal from history separately."
                return
            }
            loadedName = context.loadedName
            revision = context.revision
            savedDefinition = context.baseline
            name = context.name
        } else {
            let sourceName = run.raw["source_name"]?.stringValue ?? ""
            let targetKey = sourceName == run.name && !sourceName.isEmpty ? "saved:" + sourceName : "new"
            guard canUseDraftSlot(targetKey) else { return }
            // History opens an isolated proposal using its original saved revision, never the latest file.
            draftID = UUID()
            editorLoadID = UUID()
            loadedName = run.raw["source_name"]?.stringValue ?? ""
            revision = run.raw["source_revision"]?.intValue ?? 0
            savedDefinition = run.raw["source_saved_definition"]?.objectValue ?? [:]
            name = run.name
            if loadedName != name { loadedName = ""; revision = 0; savedDefinition = [:] }
        }
        draftKey = loadedName.isEmpty ? "new" : "saved:" + loadedName
        var edited = proposal
        edited["name"] = .string(name)
        edited.removeValue(forKey: "revision")
        definition = edited
        selectedNodeID = nil
        selectedEdgeID = nil
        connectionSourceID = nil
        appliedProposalIDs.insert(run.id)
        refinementContext = nil
        selectedRun = nil
        draftPersistenceSuspended = false
        persistDraft(reconnectBuilder: false)
        isEditing = true
        parallel.setWorkflowTaskIDs([])
    }
}
