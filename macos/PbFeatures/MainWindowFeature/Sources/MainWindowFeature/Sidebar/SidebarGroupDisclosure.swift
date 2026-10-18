import PbUI
import SwiftUI

// MARK: - SidebarGroupDisclosure

/// The existing group disclosure glyph, readable on a natively emphasized selection.
struct SidebarGroupDisclosure: View {
    let isExpanded: Bool
    let reduceMotion: Bool
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Image(systemName: "chevron.right")
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .animation(PbMotion.disclosure(reduceMotion: reduceMotion), value: isExpanded)
            .font(.pb(.caption, weight: .semibold))
            .foregroundStyle(prominence == .increased ? Color.onAccent : Color.secondaryText)
            .frame(width: PbRadius.Metrics.rowChevronFrame, height: PbRadius.Metrics.rowChevronFrame)
            .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview("Group disclosure - light") {
    SidebarGroupDisclosure(isExpanded: false, reduceMotion: true)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.sidebarBG)
        .preferredColorScheme(.light)
}

#Preview("Group disclosure - dark") {
    SidebarGroupDisclosure(isExpanded: true, reduceMotion: true)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.sidebarBG)
        .preferredColorScheme(.dark)
}

#Preview("Group disclosure emphasized - light") {
    SidebarGroupDisclosure(isExpanded: false, reduceMotion: true)
        .environment(\.backgroundProminence, .increased)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.accentFill)
        .preferredColorScheme(.light)
}

#Preview("Group disclosure emphasized - dark") {
    SidebarGroupDisclosure(isExpanded: true, reduceMotion: true)
        .environment(\.backgroundProminence, .increased)
        .padding(PbRadius.Metrics.spacing16)
        .background(Color.accentFill)
        .preferredColorScheme(.dark)
}
#endif
