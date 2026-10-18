import Foundation
import MonitorCore

// MARK: - WorkflowVM generation

extension WorkflowVM {
    func generate() {
        guard !isBusy else { return }
        reconnectBuilderSession()
        guard !builderDispatchPending, selectedRun == nil else {
            errorText = "The workflow agent is already starting or running."
            return
        }
        if draftKey == nil { draftKey = loadedName.isEmpty ? "new" : "saved:" + loadedName }
        builderDispatchPending = true
        guard persistDraft(reconnectBuilder: false) else { builderDispatchPending = false; return }
        let capturedName = name
        let capturedRepo = repo
        let capturedPrompt = prompt
        let candidate = generationAgent
        let editorContext = WorkflowRefinementContext(draftID: draftID, loadID: editorLoadID, definition: definition,
                                                      name: name, loadedName: loadedName, revision: revision, baseline: savedDefinition)
        let capturedKey = draftKey
        let context = isRefining ? editorContext : nil
        let submittedOptions = generationOptions(candidate: candidate, repo: capturedRepo, prompt: capturedPrompt, context: context)
        perform { [weak self] in
            guard let self else { return }
            let response: [String: JSONValue]
            do {
                response = try await useCase.command("build", options: submittedOptions, positionals: [capturedName])
            } catch {
                clearBuilderDispatch(context: editorContext, key: capturedKey)
                throw error
            }
            guard let id = response["workflow_run_id"]?.stringValue, !id.isEmpty else {
                clearBuilderDispatch(context: editorContext, key: capturedKey)
                throw WorkflowUIError.missingRun
            }
            var initialRun: [String: JSONValue] = ["workflow_run_id": .string(id), "workflow_name": .string(capturedName),
                                                 "kind": .string("builder"), "status": .string("starting")]
            if let context { initialRun["editing_definition"] = .object(context.definition) }
            recordBuilderDispatch(context: editorContext, key: capturedKey, run: initialRun)
            let context = editorContext
            do {
                guard draftID == context.draftID, editorLoadID == context.loadID,
                      definition == context.definition, name == context.name, loadedName == context.loadedName,
                      revision == context.revision, savedDefinition == context.baseline else {
                    errorText = "The canvas changed while the agent started. Your edits are preserved; find the proposal in workflow history."
                    return
                }
                var active = context
                active.runID = id
                refinementContext = active
                builderDispatchPending = false
            }
            showsGenerateSheet = false
            selectedRun = WorkflowRunModel(raw: initialRun)
            persistDraft()
            isEditing = false
            await useCase.refreshTasks()
            await refresh()
        }
    }

    private func generationOptions(
        candidate: [String: JSONValue], repo: String, prompt: String, context: WorkflowRefinementContext?
    ) -> [String] {
        var options = ["--prompt=\(prompt)", "--fallbacks=\((candidate["fallbacks"] ?? .array([])).rendered())"]
            + Self.candidateOptions(candidate)
        if !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { options.append("--repo=\(repo)") }
        if let context {
            // Logical payload options: the repository transports both JSON values through disposable files.
            options.append("--definition-json=\(JSONValue.object(effectiveDefinition).rendered())")
            let source: JSONValue = .object(["name": .string(context.loadedName), "revision": .number(Double(context.revision)),
                                              "saved_definition": .object(context.baseline)])
            options.append("--source=\(source.rendered())")
        }
        return options
    }

    private func recordBuilderDispatch(context: WorkflowRefinementContext, key: String?, run: [String: JSONValue]) {
        let changed = definition != context.definition || name != context.name || loadedName != context.loadedName
            || revision != context.revision || savedDefinition != context.baseline
        if draftID == context.draftID, changed {
            clearBuilderDispatch(context: context, key: key)
        } else {
            preserveBuilderDispatch(context: context, key: key, run: run)
        }
    }

}
