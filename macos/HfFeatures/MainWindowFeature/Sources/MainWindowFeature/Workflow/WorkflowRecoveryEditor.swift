import HfUI
import SwiftUI

// MARK: - WorkflowRecoveryEditor

/// Keeps the existing native multiline editor and scrolling, growing from the compact minimum
/// to the existing maximum as the actual wrapped instructions grow. The defaulted focus request
/// is purely presentational: an explicit open issues a new token and the visible editor consumes
/// it through the public `FocusState` API, and the editor contract, bindings, sizing and keyboard
/// handling are unchanged — an automatic presentation never issues one. While empty, the editor
/// shows the placeholder as an overlay (`TextEditor` has none); the placeholder is hidden from
/// accessibility in favour of the editor's label and hint.
struct WorkflowRecoveryEditor: View {
    @Binding var text: String
    /// A purely presentational explicit-open focus request; the default has none pending, which
    /// keeps the editor exactly as before, including on first load.
    var focusRequest = WorkflowRecoveryFocusRequest()
    /// Called after a pending request has been applied, so the owner marks it consumed.
    var onFocusConsumed: () -> Void = {}
    @State private var measuredHeight = HfRadius.Metrics.recoveryEditorMinimumHeight
    @FocusState private var isFocused: Bool

    var body: some View {
        TextEditor(text: $text)
            .font(.hf(.body))
            // Bounded scope (§6.3): the recovery instructions editor's own scroll view, if one
            // exists — the growing-height measurement and focus contract are unchanged.
            .scrollChromeScope()
            .focused($isFocused)
            .frame(height: min(HfRadius.Metrics.recoveryEditorMaximumHeight,
                               max(HfRadius.Metrics.recoveryEditorMinimumHeight, measuredHeight)))
            .background(alignment: .topLeading) {
                Text(text + "\n")
                    .font(.hf(.body))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, HfRadius.Metrics.spacing5)
                    .padding(.vertical, HfRadius.Metrics.spacing8)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        if height.isFinite, height != measuredHeight { measuredHeight = height }
                    }
                    .opacity(0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(WorkflowRecoveryPanePresentation.instructionsPlaceholder)
                        .font(.hf(.body))
                        .foregroundStyle(Color.tertiaryText)
                        .padding(.horizontal, HfRadius.Metrics.spacing5)
                        .padding(.vertical, HfRadius.Metrics.spacing8)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
            .accessibilityLabel("Additional instructions")
            .accessibilityHint(WorkflowRecoveryPanePresentation.instructionsPlaceholder)
            // Runs once the editor is in the hierarchy and again for each new request.
            .task(id: focusRequest) { await applyFocusRequest() }
    }

    /// Best-effort native focus: the focus system stays free to decline the request. Focus is cleared and set again on the
    /// next turn so a repeated request lands even when it is already set, and the token is consumed only after it is applied.
    private func applyFocusRequest() async {
        guard focusRequest.isPending else { return }
        isFocused = false
        await Task.yield()
        guard !Task.isCancelled, focusRequest.isPending else { return }
        isFocused = true
        onFocusConsumed()
    }
}

#if DEBUG
#Preview("Recovery instructions - light") {
    WorkflowRecoveryEditor(text: .constant("")).frame(width: HfRadius.Metrics.formPreviewWidth).preferredColorScheme(.light)
}

#Preview("Recovery instructions - dark, wrapped") {
    WorkflowRecoveryEditor(text: .constant("Please retry after inspecting the error.\nKeep the existing changes.\nReport the remaining issue."))
        .frame(width: HfRadius.Metrics.formPreviewWidth)
.preferredColorScheme(.dark)
}
#endif
