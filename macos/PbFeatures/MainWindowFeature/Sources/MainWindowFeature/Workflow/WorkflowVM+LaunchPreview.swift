import Foundation
import MonitorCore

// MARK: - WorkflowVM launch preview

extension WorkflowVM {
    var launchPreviewOptions: [String] {
        ["--repo=\(repo)"] + (overrideOrchestrator ? Self.candidateOptions(launchAgent) : [])
    }

    var canStartWithPreview: Bool {
        showsRunSheet && launchPreview != nil && launchPreviewMessage == nil
            && !loadedName.isEmpty && !hasUnsavedChanges && !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func scheduleLaunchPreview() {
        launchPreviewTask?.cancel()
        launchPreviewTask = nil
        launchPreviewID = UUID()
        launchPreview = nil
        launchPreviewMessage = nil
        guard showsRunSheet else { return }
        guard !loadedName.isEmpty, !hasUnsavedChanges else {
            launchPreviewMessage = "Save the workflow before previewing its permissions."
            return
        }
        guard !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            launchPreviewMessage = "Choose a repository to preview orchestrator permissions."
            return
        }
        launchPreviewMessage = "Checking orchestrator permissions…"
        let requestID = launchPreviewID
        let capturedName = loadedName
        let options = launchPreviewOptions
        launchPreviewTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let self, !Task.isCancelled else { return }
            do {
                let response = try await useCase.command("preview", options: options, positionals: [capturedName])
                guard !Task.isCancelled, requestID == launchPreviewID, showsRunSheet,
                      capturedName == loadedName, options == launchPreviewOptions else { return }
                guard let preview = WorkflowPermissionPreview(response) else {
                    launchPreviewMessage = "The CLI returned no permission preview. Update Polybridge before running."
                    return
                }
                launchPreview = preview
                launchPreviewMessage = nil
            } catch {
                guard !Task.isCancelled, requestID == launchPreviewID, showsRunSheet else { return }
                launchPreviewMessage = "Unable to preview orchestrator permissions. \(Self.message(error))"
            }
        }
    }
}
