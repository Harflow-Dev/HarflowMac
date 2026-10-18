import Foundation

// MARK: - WorkflowBuilderLayout

enum WorkflowBuilderLayout {
    static func minimums(height: CGFloat) -> (canvas: CGFloat, task: CGFloat) {
        let available = max(0, height - 2)
        let task = min(260, available)
        return (min(170, min(available * 0.3, max(0, available - task))), task)
    }

    static func canSubmit(isGenerating: Bool, isBusy: Bool, name: String, repo: String, prompt: String) -> Bool {
        !isBusy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isGenerating || !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
