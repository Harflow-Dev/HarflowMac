import Foundation
import MonitorCore

// MARK: - WorkflowVM Goal

extension WorkflowVM {
    func reviseGoal(_ goal: String, runID: String, expectedRevision: Int) {
        guard let run = selectedRun, run.id == runID, run.canReviseGoal, !isBusy else { return }
        guard !goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, goal.utf8.count <= 65_536 else {
            errorText = "Goal must contain text and be at most 64 KiB of UTF-8 text."
            return
        }
        perform { [weak self] in
            guard let self else { return }
            _ = try await useCase.command("revise-goal",
                                          options: ["--monitor", "--goal=\(goal)", "--expected-revision=\(expectedRevision)"], positionals: [runID])
            await refresh()
        }
    }
}
