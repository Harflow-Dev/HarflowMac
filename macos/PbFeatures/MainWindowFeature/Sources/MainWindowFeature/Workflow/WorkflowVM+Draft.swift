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
            if builderSession == nil, !builderDispatchPending, (!loadedName.isEmpty && name == loadedName && definition == savedDefinition)
                || (loadedName.isEmpty && name.isEmpty && definition == Self.starterDefinition()) {
                try draftStore.remove(key: key)
            } else {
                var draft: [String: JSONValue] = [
                    "draft_id": .string(draftID.uuidString), "name": .string(name), "loaded_name": .string(loadedName), "revision": .number(Double(revision)),
                    "definition": .object(definition), "saved_definition": .object(savedDefinition)
                 ]
                if let builderSession { draft["builder_session"] = .object(builderSession) }
                if builderDispatchPending {
                    draft["builder_dispatch_pending"] = .bool(true)
                    draft["builder_dispatch_owner"] = .string(Self.builderDispatchOwner)
                }
                try draftStore.save(draft, key: key)
            }
            return true
        } catch {
            errorText = "Unable to preserve workflow draft: \(Self.message(error))"
            return false
        }
    }

    private func adoptDraftCompletion() -> Bool {
        guard let completion = WorkflowDraftCompletion.completed[draftID], completion.revision > revision else { return true }
        guard canUseDraftSlot("saved:" + completion.name) else { return false }
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
            draftID = draft["draft_id"]?.stringValue.flatMap(UUID.init(uuidString:)) ?? UUID()
            editorLoadID = UUID()
            selectedRun = nil
            name = draft["name"]?.stringValue ?? ""
            loadedName = draft["loaded_name"]?.stringValue ?? ""
            revision = draft["revision"]?.intValue ?? 0
            savedDefinition = draft["saved_definition"]?.objectValue ?? [:]
            definition = restored
            builderDispatchPending = restoredBuilderDispatchPending(draft, key: key)
            selectedNodeID = nil
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
        let target = "saved:" + loadedName
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
