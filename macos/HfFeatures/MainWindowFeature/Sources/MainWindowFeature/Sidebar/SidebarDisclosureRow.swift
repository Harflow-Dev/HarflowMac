import HfUI
import SwiftUI

// MARK: - SidebarNativePresentationReport

/// Combined occupied-height report for a hosted disclosure row. `progress` is the actual
/// presentation progress; `logicalTarget` is the FINAL logical target — `isVisible ? 1 : 0` —
/// never the interim `appeared` flag, so a fresh visible row presenting from zero stays
/// unsettled until its presentation really commits the target. `authorityGeneration` is the
/// reporting authority captured when the cell's root was configured (renewed on every
/// association, root refresh and detach): it participates in the report's value equality, so a
/// root refresh that re-reports an IDENTICAL endpoint still re-emits through the preference
/// channel and confirms the CURRENT authority — otherwise an identical value would be
/// suppressed as unchanged after the refresh and the new authority would never be recorded.
struct SidebarNativePresentationReport: Equatable, Sendable {
    let progress: CGFloat
    let naturalHeight: CGFloat
    let logicalTarget: CGFloat
    let authorityGeneration: Int

    var occupiedHeight: CGFloat { naturalHeight * progress }
    /// Settled iff the actual presentation has reached its final logical target.
    var isSettled: Bool { progress == logicalTarget }
}

// MARK: - SidebarDisclosureRow

/// Measures a row before opening it, keeping native List insertion and removal reversible.
struct SidebarDisclosureRow<Content: View>: View {
    let isVisible: Bool
    private let minimumHeight: CGFloat
    private let reportAuthority: Int
    private let content: () -> Content
    private let onOccupiedHeight: (@MainActor @Sendable (CGFloat) -> Void)?
    private let onPresentation: (@MainActor @Sendable (SidebarNativePresentationReport) -> Void)?
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.hfReduceMotionOverride) private var reduceMotionOverride
    @State private var appeared: Bool
    @State private var height: CGFloat?

    init(isVisible: Bool, animate: Bool, minimumHeight: CGFloat = HfRadius.Metrics.zero,
         reportAuthority: Int = 0,
         onOccupiedHeight: (@MainActor @Sendable (CGFloat) -> Void)? = nil,
         onPresentation: (@MainActor @Sendable (SidebarNativePresentationReport) -> Void)? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.isVisible = isVisible
        self.minimumHeight = minimumHeight
        self.reportAuthority = reportAuthority
        self.content = content
        self.onOccupiedHeight = onOccupiedHeight
        self.onPresentation = onPresentation
        _appeared = State(initialValue: !animate)
    }

    private var reduceMotion: Bool {
        HfMotion.reduceMotion(override: reduceMotionOverride, system: systemReduceMotion)
    }

    var body: some View {
        if reduceMotion {
            content()
                .frame(minHeight: minimumHeight)
                .animation(HfMotion.arrival) { row in row.opacity(isVisible && appeared ? 1 : 0) }
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
                .animation(HfMotion.disclosure(reduceMotion: false)) { row in
                    // Enter from above the child slot and retract toward the parent. The
                    // top clip keeps this movement aligned with the shrinking List row.
                    row.offset(y: isVisible && appeared ? HfRadius.Metrics.zero : -(height ?? HfRadius.Metrics.zero))
                        .frame(height: isVisible && appeared ? nil : HfRadius.Metrics.zero, alignment: .top)
                        .opacity(isVisible && appeared ? 1 : 0)
                        .clipped()
                        .modifier(SidebarOccupiedHeightReporter(
                            progress: isVisible && appeared ? 1 : 0,
                            logicalTarget: isVisible ? 1 : 0,
                            authorityGeneration: reportAuthority,
                            naturalHeight: onOccupiedHeight == nil && onPresentation == nil ? nil : height
                        ))
                }
                .onPreferenceChange(SidebarOccupiedHeight.self) { report in
                    guard let report, report.occupiedHeight.isFinite,
                          report.occupiedHeight >= HfRadius.Metrics.zero else { return }
                    MainActor.assumeIsolated {
                        onOccupiedHeight?(report.occupiedHeight)
                        onPresentation?(report)
                    }
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

/// Reports presentation progress without changing the original disclosure layout. The report
/// carries the ACTUAL progress, the natural height, the final LOGICAL target and the reporting
/// authority generation, so settlement is decided by presentation state — never by height
/// comparison — and a refreshed root re-emits even an identical endpoint.
private struct SidebarOccupiedHeightReporter: ViewModifier, @MainActor Animatable {
    var progress: CGFloat
    let logicalTarget: CGFloat
    let authorityGeneration: Int
    let naturalHeight: CGFloat?

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.preference(
            key: SidebarOccupiedHeight.self,
            value: naturalHeight.map { height in
                SidebarNativePresentationReport(progress: progress, naturalHeight: height,
                                                logicalTarget: logicalTarget,
                                                authorityGeneration: authorityGeneration)
            }
        )
    }
}

private struct SidebarOccupiedHeight: PreferenceKey {
    static let defaultValue: SidebarNativePresentationReport? = nil
    static func reduce(value: inout SidebarNativePresentationReport?,
                       nextValue: () -> SidebarNativePresentationReport?) {
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
        Text("Workflow child").padding(HfRadius.Metrics.spacing12)
    }.preferredColorScheme(.light)
}

#Preview("Sidebar disclosure - dark") {
    SidebarDisclosureRow(isVisible: true, animate: true) {
        Text("Workflow child").padding(HfRadius.Metrics.spacing12)
    }.preferredColorScheme(.dark)
}
#endif
