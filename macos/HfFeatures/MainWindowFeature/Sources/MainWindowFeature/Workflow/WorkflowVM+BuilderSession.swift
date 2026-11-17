import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowVM builder session persistence

extension WorkflowVM {
    static let builderDispatchOwner = UUID().uuidString

    var builderSession: [String: JSONValue]? {
        guard let run = selectedRun, run.isBuilder, let context = refinementContext, context.runID == run.id else { return nil }
        guard let builderRuntime else { return nil }
        return ["runtime_binding": .object(WorkflowBuilderBinding(builderRuntime).raw), "run": .object(run.raw), "context": .object([
            "definition": .object(context.definition), "name": .string(context.name), "loaded_name": .string(context.loadedName),
            "revision": .number(Double(context.revision)), "baseline": .object(context.baseline)
        ])]
    }

    func restoreBuilderSession(_ session: [String: JSONValue]) {
        guard let runtime = try? useCase.activityRuntime(),
              WorkflowBuilderBinding(raw: session["runtime_binding"]?.objectValue) == WorkflowBuilderBinding(runtime) else {
            builderDispatchPending = true
            errorText = "The workflow agent runtime cannot be verified. Reopen the draft with its original runtime."
            return
        }
        guard let raw = session["run"]?.objectValue, let context = session["context"]?.objectValue else { return }
        let run = WorkflowRunModel(raw: raw)
        guard run.isBuilder, !run.id.isEmpty else { return }
        refinementContext = WorkflowRefinementContext(
            draftID: draftID, loadID: editorLoadID, definition: context["definition"]?.objectValue ?? definition,
            name: context["name"]?.stringValue ?? name, loadedName: context["loaded_name"]?.stringValue ?? loadedName,
            revision: context["revision"]?.intValue ?? revision, baseline: context["baseline"]?.objectValue ?? savedDefinition,
            runID: run.id
        )
        builderRuntime = runtime
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

    @discardableResult
    func preserveBuilderDispatch(context: WorkflowRefinementContext, key: String?, run: [String: JSONValue],
                                 attempt: WorkflowBuilderAttempt) -> Bool {
        guard let key else { return false }
        do {
            guard var draft = try draftStore.load(key: key), ownsBuilderAttempt(draft, attempt: attempt) else { return false }
            draft.removeValue(forKey: "builder_dispatch_pending")
            draft.removeValue(forKey: "builder_dispatch_owner")
            draft.removeValue(forKey: "builder_dispatch_attempt")
            draft["builder_session"] = .object(["runtime_binding": .object(WorkflowBuilderBinding(attempt.runtime).raw),
                "run": .object(run), "context": .object([
                "definition": .object(context.definition), "name": .string(context.name), "loaded_name": .string(context.loadedName),
                "revision": .number(Double(context.revision)), "baseline": .object(context.baseline)
            ])])
            try draftStore.save(draft, key: key)
            return true
        } catch {
            if builderContextIsCurrent(context, attempt: attempt) {
                errorText = "Unable to preserve workflow harness session: \(Self.message(error))"
            }
            return false
        }
    }

    func clearBuilderDispatch(context: WorkflowRefinementContext, key: String?, attempt: WorkflowBuilderAttempt) {
        guard let key else { return }
        do {
            guard var draft = try draftStore.load(key: key), ownsBuilderAttempt(draft, attempt: attempt) else { return }
            draft.removeValue(forKey: "builder_dispatch_pending")
            draft.removeValue(forKey: "builder_dispatch_owner")
            draft.removeValue(forKey: "builder_dispatch_attempt")
            try draftStore.save(draft, key: key)
            if draftID == context.draftID, builderAttempt?.id == attempt.id { builderDispatchPending = false; builderAttempt = nil }
        } catch {
            if builderContextIsCurrent(context, attempt: attempt) {
                errorText = "Unable to clear workflow agent dispatch: \(Self.message(error))"
            }
        }
    }

    /// Explicit canvas/proposal actions release only the exact verified session they display.
    func releaseBuilderSession() -> Bool {
        guard validateBuilderRuntime(), let run = selectedRun, let runtime = builderRuntime else { return false }
        guard let key = draftKey else { return true }
        do {
            guard var draft = try draftStore.load(key: key) else { return true }
            guard draft["draft_id"]?.stringValue == draftID.uuidString else { return false }
            guard hasBuilderMetadata(draft) else { return true }
            let binding = WorkflowBuilderBinding(raw: draft["builder_session"]?["runtime_binding"]?.objectValue)
            guard draft["builder_dispatch_pending"] == nil, draft["builder_dispatch_attempt"] == nil,
                  draft["builder_session"]?["run"]?["workflow_run_id"]?.stringValue == run.id,
                  binding == WorkflowBuilderBinding(runtime) else { return false }
            draft.removeValue(forKey: "builder_session")
            try draftStore.save(draft, key: key)
            return true
        } catch {
            errorText = "Unable to preserve the canvas transition: \(Self.message(error))"
            return false
        }
    }

    func restoredBuilderDispatchPending(_ draft: [String: JSONValue], key _: String) -> Bool {
        guard hasBuilderMetadata(draft) else { return false }
        if draft["builder_session"] != nil { return true }
        errorText = "The previous workflow agent request may have started. Check workflow history before starting another request."
        return true
    }
}
