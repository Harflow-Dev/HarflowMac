import PbUI
import SwiftUI

// MARK: - SidebarWorkflowDefinitionRow

/// One saved workflow definition row: the native `Label` anatomy — a `Text` title beside the
/// existing SF Symbol — with the title in full-contrast `primaryText`, or `onAccent` when the row's
/// own native `backgroundProminence` is `.increased`, matching `TaskRow` (Phase 1 native
/// correction: the inline `Label` read grey in both appearances, selected and unselected, while
/// sibling icons and task titles were full contrast). The explicit foreground applies only to the
/// title text; the icon keeps its system-managed colour.
struct SidebarWorkflowDefinitionRow: View {
    let title: String
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(prominence == .increased ? Color.onAccent : Color.primaryText)
        } icon: {
            Image(systemName: "point.3.connected.trianglepath.dotted")
        }
    }
}

#if DEBUG
#Preview("Saved workflow definition - light") {
    SidebarWorkflowDefinitionRow(title: "Dummy saved workflow")
        .font(.pb(.body, weight: .medium))
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.sidebarBG)
        .preferredColorScheme(.light)
}

#Preview("Saved workflow definition - dark") {
    SidebarWorkflowDefinitionRow(title: "Dummy saved workflow")
        .font(.pb(.body, weight: .medium))
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.sidebarBG)
        .preferredColorScheme(.dark)
}

#Preview("Saved workflow definition emphasized - light") {
    SidebarWorkflowDefinitionRow(title: "Dummy saved workflow")
        .font(.pb(.body, weight: .medium))
        .environment(\.backgroundProminence, .increased)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.accentFill)
        .preferredColorScheme(.light)
}

#Preview("Saved workflow definition emphasized - dark") {
    SidebarWorkflowDefinitionRow(title: "Dummy saved workflow")
        .font(.pb(.body, weight: .medium))
        .environment(\.backgroundProminence, .increased)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.accentFill)
        .preferredColorScheme(.dark)
}
#endif
