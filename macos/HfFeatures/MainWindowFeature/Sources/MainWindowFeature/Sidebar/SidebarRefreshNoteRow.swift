import HfUI
import SwiftUI

// MARK: - SidebarRefreshNoteRow

/// The note above the lists when the last refresh failed (`.hd-ev-note`): one line of copy and a ghost Retry on a danger
/// tint. The full message is the title bar dot's help text.
struct SidebarRefreshNoteRow: View {
    let retry: () -> Void

    var body: some View {
        HStack(spacing: HfRadius.Metrics.spacing8) {
            Text(SidebarRefreshNote.title)
                .font(.hf(.secondary))
                .foregroundStyle(Color.primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(SidebarRefreshNote.retryTitle, action: retry)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityIdentifier("sidebar-refresh-retry")
        }
        .padding(.vertical, HfRadius.Metrics.spacing8)
        .padding(.leading, HfRadius.Metrics.spacing12)
        .padding(.trailing, HfRadius.Metrics.spacing8)
        .background(Color.dangerBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sidebar-refresh-note")
    }
}

#if DEBUG
#Preview("Refresh note, light") {
    SidebarRefreshNoteRow(retry: {}).frame(width: 260).padding().preferredColorScheme(.light)
}

#Preview("Refresh note, dark") {
    SidebarRefreshNoteRow(retry: {}).frame(width: 260).padding().preferredColorScheme(.dark)
}
#endif
