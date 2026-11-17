import Foundation
import MonitorCore

// MARK: - WorkflowVM draft persistence

extension WorkflowVM {
    func scheduleDraftPersistence() {
        draftWriteTask?.cancel()
        guard !draftPersistenceSuspended, selectedRun == nil || builderSession != nil, draftKey != nil else { return }
        draftWriteTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.persistDraft()
        }
    }

    @discardableResult
    func persistDraft(reconnectBuilder: Bool = true) -> Bool {
        draftWriteTask?.cancel()
        draftWriteTask = nil
        if reconnectBuilder, !draftPersistenceSuspended { reconnectBuilderSession() }
        guard !draftPersistenceSuspended, selectedRun == nil || builderSession != nil, draftKey != nil else { return false }
        guard adoptDraftCompletion() else { return false }
        guard let key = draftKey else { return false }
        do {
            let existing = try draftStore.load(key: key)
            if let existing, existing["draft_id"]?.stringValue != draftID.uuidString {
                errorText = "The workflow draft belongs to another editor. Reopen it before saving."
                return false
            }
            let retained = existing.map(hasBuilderMetadata) ?? false
            if !retained, builderSession == nil, !builderDispatchPending, (!loadedName.isEmpty && name == loadedName && definition == savedDefinition)
                || (loadedName.isEmpty && name.isEmpty && definition == Self.starterDefinition()) {
                try draftStore.remove(key: key)
            } else {
                var draft: [String: JSONValue] = [
                    "draft_id": .string(draftID.uuidString), "name": .string(name), "loaded_name": .string(loadedName), "revision": .number(Double(revision)),
                    "definition": .object(definition), "saved_definition": .object(savedDefinition)
                 ]
                draft = retainingBuilderMetadata(in: draft, existing: existing)
                try draftStore.save(draft, key: key)
            }
            return true
        } catch {
            errorText = "Unable to preserve workflow draft: \(Self.message(error))"
            return false
        }
    }

    private func retainingBuilderMetadata(in value: [String: JSONValue], existing: [String: JSONValue]?) -> [String: JSONValue] {
        var draft = value
        let retained = existing.map(hasBuilderMetadata) ?? false
        for (field, value) in existing ?? [:] where field.hasPrefix("builder_") { draft[field] = value }
        if let builderSession, canUpdateBuilderSession(builderSession, existing: existing) {
            draft["builder_session"] = .object(builderSession)
        }
        if builderDispatchPending, !retained, let builderAttempt {
            draft["builder_dispatch_pending"] = .bool(true)
            draft["builder_dispatch_owner"] = .string(Self.builderDispatchOwner)
            draft["builder_dispatch_attempt"] = .object(builderAttempt.raw)
        }
        return draft
    }

    private func canUpdateBuilderSession(_ session: [String: JSONValue], existing: [String: JSONValue]?) -> Bool {
        guard let existing, hasBuilderMetadata(existing) else { return true }
        return existing["builder_session"]?["run"]?["workflow_run_id"] == session["run"]?["workflow_run_id"]
            && existing["builder_session"]?["runtime_binding"] == session["runtime_binding"]
            && existing["builder_dispatch_attempt"] == nil
    }

    private func adoptDraftCompletion() -> Bool {
        guard let completion = WorkflowDraftCompletion.completed[draftID], completion.revision > revision else { return true }
        guard !blocksBuilderDraftCleanup(), !blocksBuilderDraftCleanup(key: "saved:" + completion.name),
              canUseDraftSlot("saved:" + completion.name) else { return false }
        let unchanged = effectiveDefinition == completion.submitted
        draftPersistenceSuspended = true
        revision = completion.revision
        loadedName = completion.name
        savedDefinition = completion.saved
        draftKey = "saved:" + completion.name
        if unchanged { definition = completion.saved }
        draftPersistenceSuspended = false
        return true
    }

    @discardableResult
    func restoreDraft() -> Bool {
        guard let key = draftKey else { return false }
        do {
            guard let draft = try draftStore.load(key: key), let restored = draft["definition"]?.objectValue else { return false }
            draftPersistenceSuspended = true
            defer { draftPersistenceSuspended = false }
            resetEditHistory()
            draftID = draft["draft_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
            editorLoadID = UUID()
            selectedRun = nil
            name = draft["name"]?.stringValue ?? ""
            loadedName = draft["loaded_name"]?.stringValue ?? ""
            revision = draft["revision"]?.intValue ?? 0
            savedDefinition = WorkflowStandalone.normalized(draft["saved_definition"]?.objectValue ?? [:])
            definition = WorkflowStandalone.normalized(restored)
            builderDispatchPending = restoredBuilderDispatchPending(draft, key: key)
            selectedNodeID = WorkflowStandalone.orchestratorID
            selectedEdgeID = nil
            isEditing = true
            parallel.setWorkflowTaskIDs([])
            if let session = draft["builder_session"]?.objectValue { restoreBuilderSession(session) }
            return true
        } catch {
            errorText = "Unable to restore workflow draft: \(Self.message(error))"
            return false
        }
    }

    func blocksBuilderDraftCleanup(key: String? = nil) -> Bool {
        do {
            if let key = key ?? draftKey, let draft = try draftStore.load(key: key), hasBuilderMetadata(draft) {
                errorText = "The workflow agent association must be resolved before draft cleanup or renaming."
                return true
            }
            return false
        } catch {
            errorText = "Unable to inspect workflow agent association: \(Self.message(error))"
            return true
        }
    }

    func canUseDraftSlot(_ key: String) -> Bool {
        do {
            guard let existing = try draftStore.load(key: key), existing["draft_id"]?.stringValue != draftID.uuidString else { return true }
            errorText = "Another unsaved workflow draft exists. Open and save that draft before creating a copy or applying this proposal."
            return false
        } catch {
            errorText = "Unable to check workflow draft: \(Self.message(error))"
            return false
        }
    }

    func finishDraftSave(previousKey: String?) {
        guard !blocksBuilderDraftCleanup(key: previousKey) else { return }
        let target = "saved:" + loadedName
        guard !blocksBuilderDraftCleanup(key: target) else { return }
        do {
            if hasUnsavedChanges {
                guard canUseDraftSlot(target) else { return }
                draftKey = target
                guard persistDraft() else { return }
                // Keep the original until the replacement is durably written.
                guard try draftStore.load(key: target)?["draft_id"]?.stringValue == draftID.uuidString else { return }
            } else {
                guard previousKey == target || canUseDraftSlot(target) else { return }
                draftKey = target
                try draftStore.remove(key: target)
            }
            if let previousKey, previousKey != target { try draftStore.remove(key: previousKey) }
        } catch {
            errorText = "Workflow saved, but draft cleanup failed: \(Self.message(error))"
        }
    }
}
