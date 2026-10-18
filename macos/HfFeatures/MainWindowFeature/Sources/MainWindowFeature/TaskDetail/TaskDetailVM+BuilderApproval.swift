import Foundation
import HfCommon
import MonitorCore

// MARK: - TaskDetailVM builder approval

extension TaskDetailVM {
    var harflowApprovalBackend: String? {
        guard isWorkflowBuilder, let task else { return nil }
        let diagnostics = rawEvents.map(\.rawLine) + [useCase.snapshot(currentTaskID)?.summary ?? task.summary ?? ""]
        return diagnostics.contains { $0.contains("MCP tool call requires approval, but approval policy is never") } ? task.backend : nil
    }

    func didTapAllowHarflowTools() {
        guard let backend = harflowApprovalBackend else { return }
        let id = currentTaskID
        publishDialog("Always allow Harflow tools for \(backend.capitalized)?",
                      description: "Future \(backend.capitalized) tasks will allow Harflow MCP tools without asking. "
                        + "Other tools keep their current approvals. This will not resume the builder automatically.") {
            AlertAction(title: "Always allow") { [weak self] in
                guard let self else { return }
                let capturedUseCase = useCase
                Task {
                    do {
                        _ = try await capturedUseCase.allowHarflowTools(backend: backend)
                        capturedUseCase.setOutcome(id, "Harflow tools are allowed. Continue the builder conversation when ready.")
                    } catch {
                        capturedUseCase.setOutcome(id, "Couldn't update tool approvals: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
}
