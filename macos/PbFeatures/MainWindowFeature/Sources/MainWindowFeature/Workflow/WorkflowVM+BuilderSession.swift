import Foundation
import MonitorCore

// MARK: - WorkflowVM builder session persistence

extension WorkflowVM {
    static let builderDispatchOwner = UUID().uuidString

    var builderSession: [String: JSONValue]? {
        guard let run = selectedRun, run.isBuilder, let context = refinementContext, context.runID == run.id else { return nil }
        return ["run": .object(run.raw), "context": .object([
            "definition": .object(context.definition), "name": .string(context.name), "loaded_name": .string(context.loadedName),
            "revision": .number(Double(context.revision)), "baseline": .object(context.baseline)
        ])]
    }

    func restoreBuilderSession(_ session: [String: JSONValue]) {
        guard let raw = session["run"]?.objectValue, let context = session["context"]?.objectValue else { return }
        let run = WorkflowRunModel(raw: raw)
        guard run.isBuilder, !run.id.isEmpty else { return }
        refinementContext = WorkflowRefinementContext(
            draftID: draftID, loadID: editorLoadID, definition: context["definition"]?.objectValue ?? definition,
            name: context["name"]?.stringValue ?? name, loadedName: context["loaded_name"]?.stringValue ?? loadedName,
            revision: context["revision"]?.intValue ?? revision, baseline: context["baseline"]?.objectValue ?? savedDefinition,
            runID: run.id
        )
        builderDispatchPending = false
        selectedRun = run
        isEditing = false
        updateActivityMembership()
    }

    func reconnectBuilderSession() {
        guard selectedRun == nil, let key = draftKey else { return }
        do {
            guard let draft = try draftStore.load(key: key), draft["draft_id"]?.stringValue == draftID.uuidString else { return }
            builderDispatchPending = restoredBuilderDispatchPending(draft, key: key)
            if let session = draft["builder_session"]?.objectValue { restoreBuilderSession(session) }
        } catch {
            errorText = "Unable to reconnect workflow agent: \(Self.message(error))"
        }
    }

    func preserveBuilderDispatch(context: WorkflowRefinementContext, key: String?, run: [String: JSONValue]) {
        guard let key else { return }
        do {
            var draft = try draftStore.load(key: key) ?? [
                "draft_id": .string(context.draftID.uuidString), "name": .string(context.name), "loaded_name": .string(context.loadedName),
                "revision": .number(Double(context.revision)), "definition": .object(context.definition), "saved_definition": .object(context.baseline)
            ]
            guard draft["draft_id"]?.stringValue == context.draftID.uuidString else { return }
            draft.removeValue(forKey: "builder_dispatch_pending")
            draft.removeValue(forKey: "builder_dispatch_owner")
            draft["builder_session"] = .object(["run": .object(run), "context": .object([
                "definition": .object(context.definition), "name": .string(context.name), "loaded_name": .string(context.loadedName),
                "revision": .number(Double(context.revision)), "baseline": .object(context.baseline)
            ])])
            try draftStore.save(draft, key: key)
        } catch {
            errorText = "Unable to preserve workflow agent session: \(Self.message(error))"
        }
    }

    func clearBuilderDispatch(context: WorkflowRefinementContext, key: String?) {
        if draftID == context.draftID { builderDispatchPending = false }
        guard let key else { return }
        do {
            guard var draft = try draftStore.load(key: key), draft["draft_id"]?.stringValue == context.draftID.uuidString else { return }
            draft.removeValue(forKey: "builder_dispatch_pending")
            draft.removeValue(forKey: "builder_dispatch_owner")
            try draftStore.save(draft, key: key)
        } catch {
            errorText = "Unable to clear workflow agent dispatch: \(Self.message(error))"
        }
    }

    func restoredBuilderDispatchPending(_ draft: [String: JSONValue], key: String) -> Bool {
        guard draft["builder_dispatch_pending"]?.boolValue == true else { return false }
        if draft["builder_session"] != nil { return false }
        guard draft["builder_dispatch_owner"]?.stringValue != Self.builderDispatchOwner else { return true }
        var interrupted = draft
        interrupted.removeValue(forKey: "builder_dispatch_pending")
        interrupted.removeValue(forKey: "builder_dispatch_owner")
        do {
            try draftStore.save(interrupted, key: key)
            errorText = "The previous workflow agent request was interrupted before its run ID was received. "
                + "It may already have created a builder run. Check workflow history before starting another request."
        } catch {
            errorText = "Unable to clear the interrupted workflow agent request: \(Self.message(error)). "
                + "Check workflow history before starting another request."
        }
        return false
    }

}
