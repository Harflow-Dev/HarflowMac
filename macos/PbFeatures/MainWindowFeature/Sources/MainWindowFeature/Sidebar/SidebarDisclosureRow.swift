import PbUI
import SwiftUI

// MARK: - SidebarDisclosureRow

/// Measures a row before opening it, keeping native List insertion and removal reversible.
struct SidebarDisclosureRow<Content: View>: View {
    let isVisible: Bool
    private let minimumHeight: CGFloat
    private let content: () -> Content
    private let onOccupiedHeight: (@MainActor @Sendable (CGFloat) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.pbReduceMotionOverride) private var reduceMotionOverride
    @State private var appeared: Bool
    @State private var height: CGFloat?

    init(isVisible: Bool, animate: Bool, minimumHeight: CGFloat = PbRadius.Metrics.zero,
         onOccupiedHeight: (@MainActor @Sendable (CGFloat) -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.isVisible = isVisible
        self.minimumHeight = minimumHeight
        self.content = content
        self.onOccupiedHeight = onOccupiedHeight
        _appeared = State(initialValue: !animate)
    }

    private var reduceMotion: Bool {
        PbMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
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
                    row.offset(y: isVisible && appeared ? PbRadius.Metrics.zero : -(height ?? PbRadius.Metrics.zero))
                        .frame(height: isVisible && appeared ? nil : PbRadius.Metrics.zero, alignment: .top)
                        .opacity(isVisible && appeared ? 1 : 0)
                        .clipped()
                        .modifier(SidebarOccupiedHeightReporter(
                            progress: isVisible && appeared ? 1 : 0,
                            naturalHeight: onOccupiedHeight == nil ? nil : height
                        ))
                }
                .onPreferenceChange(SidebarOccupiedHeight.self) { occupied in
                    guard let occupied, occupied.isFinite, occupied >= PbRadius.Metrics.zero else { return }
                    MainActor.assumeIsolated { onOccupiedHeight?(occupied) }
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

// MARK: - Native occupied-height reporting

/// Reports animation presentation progress without changing the original disclosure layout.
private struct SidebarOccupiedHeightReporter: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    let naturalHeight: CGFloat?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.preference(key: SidebarOccupiedHeight.self, value: naturalHeight.map { $0 * progress })
    }
}

private struct SidebarOccupiedHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

private struct SidebarRowHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

#if DEBUG
#Preview("Sidebar disclosure - light") {
    SidebarDisclosureRow(isVisible: true, animate: true) {
        Text("Workflow child").padding(PbRadius.Metrics.spacing12)
    }.preferredColorScheme(.light)
}

#Preview("Sidebar disclosure - dark") {
    SidebarDisclosureRow(isVisible: true, animate: true) {
        Text("Workflow child").padding(PbRadius.Metrics.spacing12)
    }.preferredColorScheme(.dark)
}
#endif
