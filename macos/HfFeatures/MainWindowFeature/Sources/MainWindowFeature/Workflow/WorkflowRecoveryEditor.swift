import HfUI
import SwiftUI

// MARK: - WorkflowRecoveryEditor

/// Keeps the existing native multiline editor and scrolling, growing from the compact minimum
/// to the existing maximum as the actual wrapped instructions grow. The defaulted focus input
/// is purely presentational: an explicit open may request native focus through the public
/// `FocusState` API, and the editor contract, bindings, sizing and keyboard handling are
/// unchanged — an automatic panel presentation never sets it.
struct WorkflowRecoveryEditor: View {
    @Binding var text: String
    /// A purely presentational explicit-open focus request; `false` keeps the editor exactly
    /// as before, including on first load.
    var isFocusRequested = false
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
            .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.cardBorder))
            .accessibilityLabel("Additional instructions")
            .onAppear { applyFocusRequest() }
            .onChange(of: isFocusRequested) { applyFocusRequest() }
    }

    /// Best-effort native focus: the focus system stays free to decline the request.
    private func applyFocusRequest() {
        if isFocusRequested { isFocused = true }
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
