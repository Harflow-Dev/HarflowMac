import Foundation

// MARK: - WorkflowBuilderLayout

enum WorkflowBuilderLayout {
    /// Budgets the actual detail viewport, including exactly one divider. The canvas retains its
    /// normal node geometry and scrolls; a narrow viewport never selects a different layout.
    static func widths(viewport: CGFloat) -> (canvas: CGFloat, activity: CGFloat, divider: CGFloat) {
        let width = viewport.isFinite ? max(0, viewport) : 0
        let divider = min(1, width)
        let available = width - divider
        let activity = min(460, available)
        return (available - activity, activity, divider)
    }

    static func canSubmit(isGenerating: Bool, isBusy: Bool, name: String, repo: String, prompt: String) -> Bool {
        !isBusy && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (isGenerating || !repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
