import Foundation
import MonitorCore
import PbCommon

// MARK: - WorkflowVM Save

extension WorkflowVM {
    var effectiveDefinition: [String: JSONValue] {
        var value = definition
        value["name"] = .string(name)
        value["nodes"] = .array(WorkflowJSON.objects(value["nodes"]).map { node in
            var node = node
            node["branch_mode"] = .string("auto")
            return .object(node)
        })
        return value
    }

    func scheduleValidation() {
        validationTask?.cancel()
        validationTask = nil
        validationID = UUID()
        validatedDefinition = nil
        validationDependencies = [:]
        nativeSubagentsAvailable = false
        if canonicalValidationSource.map({ WorkflowRetryMetadata.topology($0) != WorkflowRetryMetadata.topology(definition) }) == true {
            canonicalValidationDefinition = nil
            canonicalValidationSource = nil
        }
        guard selectedRun == nil else { validationMessage = nil; return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validationMessage = "Enter a workflow name."
            return
        }
        validationMessage = "Checking workflow…"
        guard !validationSuspended else { return }
        let snapshot = effectiveDefinition
        let requestID = validationID
        validationTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                let response = try await useCase.validate(definition: .object(snapshot))
                guard !Task.isCancelled, requestID == validationID, snapshot == effectiveDefinition, selectedRun == nil else { return }
                nativeSubagentsAvailable = response["native_subagents_available"]?.boolValue ?? false
                if response["valid"]?.boolValue == true {
                    validationDependencies = response["dependencies"]?.objectValue ?? [:]
                    validatedDefinition = snapshot
                    canonicalValidationDefinition = response["definition"]?.objectValue
                    canonicalValidationSource = snapshot
                    validationMessage = nil
                } else {
                    validationMessage = response["error"]?.stringValue ?? "Workflow is invalid."
                }
            } catch {
                guard !Task.isCancelled, requestID == validationID, snapshot == effectiveDefinition else { return }
                validationMessage = "Unable to validate workflow. Update or reinstall the Polybridge CLI from this repo "
                    + "(uv tool install . --force --no-cache). \(Self.message(error))"
            }
        }
    }

    func save() {
        guard canSave else { return }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showSaveWarning("Enter a workflow name.")
            return
        }
        persistDraft()
        let snapshot = SaveSnapshot(self)
        validationTask?.cancel()
        validationTask = nil
        validationID = UUID()
        perform { [weak self] in
            guard let self, snapshot.matches(self), await validateForSave(snapshot) else { return }
            guard snapshot.matches(self) else { return }
            let response = try await useCase.save(name: snapshot.name, definition: .object(snapshot.definition), expectedRevision: snapshot.revision)
            let record = WorkflowRecord(raw: response["workflow"]?.objectValue ?? response)
            WorkflowDraftCompletion.completed[snapshot.draftID] = WorkflowDraftCompletion(
                name: snapshot.name, revision: record.revision, submitted: snapshot.definition, saved: record.definition
            )
            guard snapshot.matches(self, exactDefinition: false, exactName: false) else {
                reconcileSavedDraft(snapshot, record: record)
                return
            }
            let previousDraftKey = draftKey
            draftPersistenceSuspended = true
            revision = record.revision
            savedDefinition = record.definition
            loadedName = snapshot.name
            let hasNewerEdits = snapshot.definition != effectiveDefinition
            if !hasNewerEdits { definition = record.definition }
            draftPersistenceSuspended = false
            finishDraftSave(previousKey: previousDraftKey)
            await refresh()
            if snapshot.isFirstSave, !hasNewerEdits,
               snapshot.matches(self, revision: record.revision, definition: record.definition) {
                routing.didSaveWorkflow(name: snapshot.name)
            }
        }
    }

    private func reconcileSavedDraft(_ snapshot: SaveSnapshot, record: WorkflowRecord) {
        guard let key = snapshot.draftKey else { return }
        do {
            guard var draft = try draftStore.load(key: key),
                  draft["draft_id"]?.stringValue == snapshot.draftID.uuidString,
                  draft["revision"]?.intValue == snapshot.revision else { return }
            let current = draft["definition"]?.objectValue ?? [:]
            var effective = current
            effective["name"] = draft["name"]
            let unchanged = effective == snapshot.definition
            if !unchanged {
                draft["loaded_name"] = .string(snapshot.name)
                draft["revision"] = .number(Double(record.revision))
                draft["saved_definition"] = .object(record.definition)
                let target = "saved:" + snapshot.name
                if target != key, let existing = try draftStore.load(key: target), existing["draft_id"] != draft["draft_id"] {
                    errorText = "Workflow saved, but another draft occupies its new name. Your original draft is preserved."
                    return
                }
                try draftStore.save(draft, key: target)
                if target != key { try draftStore.remove(key: key) }
            } else {
                try draftStore.remove(key: key)
            }
            if draftID == snapshot.draftID { reloadEditorAfterLateSave(name: snapshot.name) }
        } catch {
            errorText = "Workflow saved, but draft cleanup failed: \(Self.message(error))"
        }
    }

    private func validateForSave(_ snapshot: SaveSnapshot) async -> Bool {
        if snapshot.alreadyValidated { return true }
        let validation: [String: JSONValue]
        do {
            validation = try await useCase.validate(definition: .object(snapshot.definition))
        } catch is CancellationError {
            return false
        } catch {
            if snapshot.matches(self) {
                showSaveWarning("Unable to validate workflow. Update or reinstall the Polybridge CLI from this repo. " + Self.message(error))
            }
            return false
        }
        guard snapshot.matches(self) else { return false }
        guard validation["valid"]?.boolValue == true else {
            let reason = validation["error"]?.stringValue ?? "Workflow is invalid."
            validationMessage = reason
            showSaveWarning(reason)
            return false
        }
        validatedDefinition = snapshot.definition
        validationMessage = nil
        return true
    }

    private func showSaveWarning(_ description: String) {
        publishAlert("Cannot save workflow", description: description) { AlertAction(title: "OK") }
    }
}

// MARK: - SaveSnapshot

private struct SaveSnapshot {
    let definition: [String: JSONValue]
    let name: String
    let revision: Int
    let draftID: UUID
    let editorLoadID: UUID
    let isFirstSave: Bool
    let alreadyValidated: Bool
    let draftKey: String?

    @MainActor init(_ vm: WorkflowVM) {
        self.draftKey = vm.draftKey
        self.definition = vm.effectiveDefinition
        self.name = vm.name
        self.revision = vm.revision
        self.draftID = vm.draftID
        self.editorLoadID = vm.editorLoadID
        self.isFirstSave = vm.loadedName.isEmpty
        self.alreadyValidated = vm.validatedDefinition == definition
    }

    @MainActor func matches(
        _ vm: WorkflowVM, revision: Int? = nil, definition: [String: JSONValue]? = nil,
        exactDefinition: Bool = true, exactName: Bool = true
    ) -> Bool {
        guard !Task.isCancelled, vm.selectedRun == nil else { return false }
        guard vm.draftID == draftID, vm.editorLoadID == editorLoadID, !exactName || vm.name == name else { return false }
        guard vm.revision == (revision ?? self.revision) else { return false }
        return !exactDefinition || vm.effectiveDefinition == (definition ?? self.definition)
    }
}
