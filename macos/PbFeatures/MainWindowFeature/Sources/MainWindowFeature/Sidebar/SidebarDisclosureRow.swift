import PbUI
import SwiftUI

// MARK: - SidebarDisclosureRow

/// Measures a row before opening it, keeping native List insertion and removal reversible.
struct SidebarDisclosureRow<Content: View>: View {
    let isVisible: Bool
    private let minimumHeight: CGFloat
    private let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared: Bool
    @State private var height: CGFloat?

    init(isVisible: Bool, animate: Bool, minimumHeight: CGFloat = 0, @ViewBuilder content: @escaping () -> Content) {
        self.isVisible = isVisible
        self.minimumHeight = minimumHeight
        self.content = content
        _appeared = State(initialValue: !animate)
    }

    var body: some View {
        if reduceMotion {
            content()
                .frame(minHeight: minimumHeight)
                .animation(PbMotion.arrival) { row in row.opacity(isVisible && appeared ? 1 : 0) }
                .onAppear { appeared = true }
        } else {
            content()
                .frame(minHeight: minimumHeight)
                .fixedSize(horizontal: false, vertical: true)
                .background {
                    GeometryReader { proxy in
                        Color.clear.preference(key: SidebarRowHeight.self, value: proxy.size.height)
                    }
                }
                .animation(PbMotion.disclosure(reduceMotion: false)) { row in
                    row.frame(height: isVisible && appeared ? height : 0, alignment: .top)
                        .opacity(isVisible && appeared ? 1 : 0)
                        .clipped()
                }
                .onPreferenceChange(SidebarRowHeight.self) { measured in
                    height = measured
                    appeared = true
                }
        }
    }
}

private struct SidebarRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if DEBUG
#Preview {
    SidebarDisclosureRow(isVisible: true, animate: true) { Text("Workflow child").padding(12) }
}
#endif
