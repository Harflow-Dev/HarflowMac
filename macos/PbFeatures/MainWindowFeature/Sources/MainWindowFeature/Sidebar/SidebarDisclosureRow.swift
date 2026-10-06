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
                    // Enter from above the child slot and retract toward the parent. The
                    // top clip keeps this movement aligned with the shrinking List row.
                    row.offset(y: isVisible && appeared ? 0 : -(height ?? 0))
                        .frame(height: isVisible && appeared ? height : 0, alignment: .top)
                        .opacity(isVisible && appeared ? 1 : 0)
                        .clipped()
                }
                .onPreferenceChange(SidebarRowHeight.self) { measured in
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { height = measured }
                }
                .task(id: height) {
                    guard height != nil, !appeared else { return }
                    // Mount at the measured hidden position for one frame before revealing.
                    // The view task cancels automatically if this row disappears meanwhile.
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
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
