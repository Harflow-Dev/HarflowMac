import Foundation
import HfCommon
import MonitorCore

// MARK: - WorkflowDiscardContext

struct WorkflowDiscardContext: Sendable {
    let draftID: UUID
    let editorLoadID: UUID
    let generation: UUID
    let draftKey: String?
    let name: String
    let loadedName: String
    let revision: Int
    let definition: [String: JSONValue]
    let savedDefinition: [String: JSONValue]

    @MainActor init(_ vm: WorkflowVM) {
        self.draftID = vm.draftID
        self.editorLoadID = vm.editorLoadID
        self.generation = vm.generationID
        self.draftKey = vm.draftKey
        self.name = vm.name
        self.loadedName = vm.loadedName
        self.revision = vm.revision
        self.definition = vm.definition
        self.savedDefinition = vm.savedDefinition
    }

    @MainActor func matches(_ vm: WorkflowVM) -> Bool {
        draftID == vm.draftID && editorLoadID == vm.editorLoadID && generation == vm.generationID
            && draftKey == vm.draftKey && name == vm.name && loadedName == vm.loadedName
            && revision == vm.revision && definition == vm.definition && savedDefinition == vm.savedDefinition
            && vm.isEditing && vm.selectedRun == nil && vm.initialLoadingKind == nil && !vm.initialLoadFailed
            && !vm.checkingEditorBaseline && !(vm.isRefining && vm.showsGenerateSheet) && vm.refinementContext == nil
            && vm.builderSession == nil && !vm.builderDispatchPending && !vm.draftPersistenceSuspended
            && (WorkflowDraftCompletion.completed[draftID]?.revision ?? revision) <= revision
    }
}

// MARK: - WorkflowVM saved discard confirmation

extension WorkflowVM {
    func discardChanges() {
        guard canDiscard, builderSession == nil, !builderDispatchPending else { return }
        guard !loadedName.isEmpty else { discardChanges(using: nil); return }
        let context = WorkflowDiscardContext(self)
        let requestID = UUID()
        discardRequestID = requestID
        perform { [weak self] in
            guard let self else { return }
            do {
                let response = try await useCase.command("get", options: [], positionals: [context.loadedName])
                guard discardRequestID == requestID else { return }
                guard context.matches(self) else {
                    discardRequestID = nil
                    return
                }
                guard let prepared = Self.discardRecord(response, named: context.loadedName) else {
                    discardRequestID = nil
                    refuseDiscard()
                    return
                }
                publishDialog("Discard unsaved changes?", description: "The workflow returns to revision \(prepared.revision), its last saved revision.") {
                    AlertAction(title: "Cancel", role: .cancel, isDefault: true) { [weak self] in
                        guard self?.discardRequestID == requestID else { return }
                        self?.discardRequestID = nil
                    }
                    AlertAction(title: "Discard", role: .destructive) { [weak self] in
                        self?.confirmDiscard(requestID: requestID, context: context, prepared: prepared)
                    }
                }
            } catch {
                guard discardRequestID == requestID else { return }
                discardRequestID = nil
                if context.matches(self) { refuseDiscard() }
            }
        }
    }

    private func confirmDiscard(requestID: UUID, context: WorkflowDiscardContext, prepared: WorkflowRecord) {
        guard discardRequestID == requestID else { return }
        discardRequestID = nil
        guard !isBusy, context.matches(self) else { return }
        perform { [weak self] in
            guard let self else { return }
            do {
                let response = try await useCase.command("get", options: [], positionals: [context.loadedName])
                guard context.matches(self) else { return }
                guard let current = Self.discardRecord(response, named: context.loadedName),
                      current.id == prepared.id, current.workflowID == prepared.workflowID,
                      current.revision == prepared.revision, current.definition == prepared.definition else {
                    refuseDiscard()
                    return
                }
                discardChanges(using: prepared, isCurrent: { context.matches(self) })
            } catch {
                if context.matches(self) { refuseDiscard() }
            }
        }
    }

    private static func discardRecord(_ response: [String: JSONValue], named name: String) -> WorkflowRecord? {
        guard response["workflow"] == nil || response["workflow"]?.objectValue != nil else { return nil }
        let raw = response["workflow"]?.objectValue ?? response
        guard raw["name"]?.stringValue == name, !name.isEmpty,
              let revision = raw["revision"]?.intValue, revision > 0,
              raw["revision"]?.doubleValue == Double(revision) else { return nil }
        if let value = raw["definition"] {
            guard let definition = value.objectValue, !definition.isEmpty else { return nil }
        } else {
            guard isFlatDiscardDefinition(raw) else { return nil }
        }
        return WorkflowRecord(raw: raw)
    }

    private static func isFlatDiscardDefinition(_ raw: [String: JSONValue]) -> Bool {
        // Python workflow-get returns its qualified definition directly, without a definition envelope.
        guard let nodes = raw["nodes"]?.arrayValue, let connections = raw["connections"]?.arrayValue,
              raw["orchestrator"]?.objectValue != nil,
              nodes.allSatisfy({ $0.objectValue != nil }), connections.allSatisfy({ $0.objectValue != nil }) else { return false }
        if let schema = raw["schema_version"], schema != .number(1) { return false }
        if let identity = raw["workflow_id"], identity.stringValue == nil { return false }
        return true
    }

    private func refuseDiscard() {
        errorText = "The current saved workflow could not be confirmed. Your draft is preserved."
        editorConflict = "The saved workflow changed or was replaced. Your draft is preserved. Save a copy and reload to reconcile it."
    }
}
