import Foundation
import MonitorCore

// MARK: - WorkflowVM messages

extension WorkflowVM {
    func submitWorkMessage(_ text: String, now: Bool) -> Bool {
        guard !isBusy, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let run = selectedRun else {
            // Start the builder using the same explicit generation path as the editor action.
            prepareGeneration(refining: isEditing)
            prompt = text
            return true
        }
        let runID = run.id
        perform { [weak self] in
            guard let self else { return }
            let result = try await useCase.command("send", options: ["--monitor", "--delivery=\(now ? "now" : "queue")"], positionals: [runID, text])
            errorText = WorkMessageOutcome.notice(result)
            await refresh()
        }
        return true
    }

    func cancelWorkMessage(_ messageID: String) {
        guard !isBusy, let run = selectedRun else { return }
        let runID = run.id
        perform { [weak self] in
            guard let self else { return }
            _ = try await useCase.command("cancel-message", options: ["--monitor"], positionals: [runID, messageID])
            await refresh()
        }
    }
}
