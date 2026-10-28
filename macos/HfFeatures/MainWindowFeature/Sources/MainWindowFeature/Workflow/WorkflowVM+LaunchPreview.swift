import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowVM launch preview

extension WorkflowVM {
    var launchPreviewOptions: [String] {
        ["--repo=\(repo)"] + (overrideOrchestrator ? Self.candidateOptions(launchAgent) : [])
    }

    var canStartWithPreview: Bool {
        qualification?.isReady == true && showsRunSheet && launchPreview != nil && launchPreviewMessage == nil
            && !loadedName.isEmpty && !hasUnsavedChanges && !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func scheduleLaunchPreview() {
        qualification?.prepare()
        launchPreviewTask?.cancel()
        launchPreviewTask = nil
        launchPreviewID = UUID()
        launchPreview = nil
        launchPreviewMessage = nil
        guard showsRunSheet else { qualification?.stop(); return }
        if qualification == nil { qualification = QualificationPresentation(session: useCase.qualificationSession()) }
        guard !loadedName.isEmpty, !hasUnsavedChanges else {
            launchPreviewMessage = "Save the workflow before previewing its permissions."
            return
        }
        guard !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            launchPreviewMessage = "Choose a repository to preview orchestrator permissions."
            return
        }
        launchPreviewMessage = "Check the required harness features before previewing orchestrator permissions."
        let requestID = launchPreviewID
        let capturedName = loadedName
        let options = launchPreviewOptions
        launchPreviewTask = Task { [weak self] in
            await self?.loadLaunchPreview(requestID: requestID, capturedName: capturedName, options: options)
        }
    }

    private func loadLaunchPreview(requestID: UUID, capturedName: String, options: [String]) async {
        do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
        guard !Task.isCancelled else { return }
        do {
            guard let qualification,
                  await qualification.discover(.workflow(name: capturedName, options: options)),
                  !Task.isCancelled, requestID == launchPreviewID, showsRunSheet,
                  capturedName == loadedName, options == launchPreviewOptions else { return }
            guard let runtime = qualification.runtime else { return }
            launchPreviewMessage = "Checking orchestrator permissions…"
            let response = try await useCase.command("preview", options: options, positionals: [capturedName], runtime: runtime)
            guard !Task.isCancelled, requestID == launchPreviewID, showsRunSheet,
                  capturedName == loadedName, options == launchPreviewOptions else { return }
            guard let preview = WorkflowPermissionPreview(response) else {
                launchPreviewMessage = "The CLI returned no permission preview. Update Harflow before running."
                return
            }
            launchPreview = preview
            launchPreviewMessage = nil
        } catch {
            guard !Task.isCancelled, requestID == launchPreviewID, showsRunSheet else { return }
            launchPreviewMessage = "Unable to preview orchestrator permissions. \(Self.message(error))"
        }
    }

    func start() {
        guard !loadedName.isEmpty else {
            errorText = "Save the workflow before running it."; return
        }
        guard !hasUnsavedChanges else {
            errorText = "Save your changes before running this workflow."; return
        }
        guard let preview = launchPreview, canStartWithPreview else {
            errorText = "Wait for the orchestrator permission preview before running."
            return
        }
        guard goal.utf8.count <= 65_536 else {
            errorText = "Goal must be at most 64 KiB of UTF-8 text."
            return
        }
        let capturedName = loadedName
        let capturedDefinition = definition
        let candidate = overrideOrchestrator ? launchAgent : (capturedDefinition["orchestrator"]?.objectValue ?? [:])
        let capturedIdentity = AgentUsageIdentity(backend: candidate["backend"]?.stringValue ?? "", model: candidate["model"]?.stringValue)
        let goalOptions = goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : ["--goal=\(goal)"]
        let capturedOptions = goalOptions + launchPreviewOptions + ["--monitor", "--prompt=\(prompt)", "--expected-preview-hash=\(preview.hash)"]
        perform { [weak self] in
            guard let self else { return }
            let options = capturedOptions
            let response: [String: JSONValue]
            do {
                guard let qualification,
                      await qualification.discover(.workflow(name: capturedName, options: self.launchPreviewOptions)),
                      let runtime = qualification.runtime, capturedName == loadedName, preview.hash == launchPreview?.hash, canStartWithPreview,
                      options == capturedOptions else { return }
                response = try await useCase.command("start", options: options, positionals: [capturedName], runtime: runtime)
            } catch {
                scheduleLaunchPreview()
                throw error
            }
            guard let id = response["workflow_run_id"]?.stringValue, !id.isEmpty else {
                throw WorkflowUIError.missingRun
            }
            await useCase.recordAgentUsage(capturedIdentity, acknowledgementID: "workflow:" + id)
            showsRunSheet = false
            initialLoadingKind = "run"
            initialLoadFailed = false
            selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(id), "workflow_name": .string(capturedName),
                                                 "definition": .object(capturedDefinition)])
            isEditing = false
            if routesStartedRun {
                routing.openWorkflowRun(id: id)
                await useCase.refreshTasks()
                return
            }
            await useCase.refreshTasks()
            await refresh()
        }
    }

}
