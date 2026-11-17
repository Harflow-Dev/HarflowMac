import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowBuilderSubmission

private struct WorkflowBuilderSubmission {
    let context: WorkflowRefinementContext
    let key: String
    let attempt: WorkflowBuilderAttempt
    let fence: WorkflowBuilderFence
    let generation: UUID
    let candidate: [String: JSONValue]
    let options: [String]
    let refining: Bool

    @MainActor func isCurrent(_ vm: WorkflowVM) -> Bool {
        !Task.isCancelled && fence.isCurrent() && vm.generationID == generation
            && vm.builderContextIsCurrent(context, attempt: attempt)
    }
}

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
        guard let runtime = try? useCase.activityRuntime() else {
            errorText = "The workflow agent runtime is unavailable."
            return
        }
        let attempt = WorkflowBuilderAttempt(draftID: draftID, runtime: runtime)
        builderAttempt = attempt
        builderDispatchPending = true
        guard persistDraft(reconnectBuilder: false) else { builderDispatchPending = false; return }
        guard let key = draftKey, let reserved = try? draftStore.load(key: key),
              ownsBuilderAttempt(reserved, attempt: attempt) else { return }
        let fence = WorkflowBuilderFence()
        builderSubmissionFence?.invalidate()
        builderSubmissionFence = fence
        let context = WorkflowRefinementContext(draftID: draftID, loadID: editorLoadID, definition: definition,
                                                name: name, loadedName: loadedName, revision: revision, baseline: savedDefinition)
        let submission = WorkflowBuilderSubmission(context: context, key: key, attempt: attempt, fence: fence,
            generation: generationID, candidate: generationAgent,
            options: generationOptions(candidate: generationAgent, repo: repo, prompt: prompt, context: isRefining ? context : nil),
            refining: isRefining)
        perform { [weak self] in await self?.submitBuilder(submission) }
    }

    private func submitBuilder(_ submission: WorkflowBuilderSubmission) async {
        guard submission.isCurrent(self) else {
            clearBuilderDispatch(context: submission.context, key: submission.key, attempt: submission.attempt)
            return
        }
        let response: [String: JSONValue]
        let fence = submission.fence
        do {
            response = try await useCase.boundBuilderCommand("build", options: submission.options, positionals: [submission.context.name],
                runtime: submission.attempt.runtime, isCurrent: { fence.isCurrent() })
        } catch {
            if submission.isCurrent(self) { errorText = Self.message(error) }
            return
        }
        guard let id = response["workflow_run_id"]?.stringValue, !id.isEmpty else {
            if submission.isCurrent(self) { errorText = Self.message(WorkflowUIError.missingRun) }
            return
        }
        var run: [String: JSONValue] = ["workflow_run_id": .string(id), "workflow_name": .string(submission.context.name),
                                        "kind": .string("builder"), "status": .string("starting")]
        if submission.refining { run["editing_definition"] = .object(submission.context.definition) }
        guard preserveBuilderDispatch(context: submission.context, key: submission.key, run: run, attempt: submission.attempt) else { return }
        let identity = AgentUsageIdentity(backend: submission.candidate["backend"]?.stringValue ?? "",
                                          model: submission.candidate["model"]?.stringValue)
        await useCase.recordAgentUsage(identity, acknowledgementID: "workflow:" + id)
        await adoptBuilderAcknowledgement(submission, run: run, id: id)
    }

    private func adoptBuilderAcknowledgement(_ submission: WorkflowBuilderSubmission, run: [String: JSONValue], id: String) async {
        guard submission.isCurrent(self),
              builderAcknowledgementIsCurrent(key: submission.key, draftID: submission.context.draftID,
                                               runID: id, runtime: submission.attempt.runtime) else { return }
        var active = submission.context
        active.runID = id
        builderRuntime = submission.attempt.runtime
        builderAttempt = nil
        refinementContext = active
        builderDispatchPending = false
        showsGenerateSheet = false
        selectedRun = WorkflowRunModel(raw: run)
        persistDraft()
        isEditing = false
        await useCase.refreshTasks()
        guard selectedRun?.id == id, editorLoadID == submission.context.loadID,
              (try? useCase.activityRuntime()) == submission.attempt.runtime else { _ = validateBuilderRuntime(); return }
        await refresh()
    }

    private func generationOptions(
        candidate: [String: JSONValue], repo: String, prompt: String, context: WorkflowRefinementContext?
    ) -> [String] {
        var options = ["--monitor", "--prompt=\(prompt)", "--fallbacks=\((candidate["fallbacks"] ?? .array([])).rendered())"]
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

}
