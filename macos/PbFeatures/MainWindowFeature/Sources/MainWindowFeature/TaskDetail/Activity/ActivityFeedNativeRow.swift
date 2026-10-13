//
//  ActivityFeedNativeRow.swift
//  MainWindowFeature
//
//  The activity feed's native surface: one entry model covering everything the feed shows —
//  the history header, the empty text, the timeline rows, the live tail and the bottom sentinel —
//  plus the single SwiftUI root each native row hosts. Both the measurement host and the
//  realized cells render this root at the same pinned width and with the same complete inherited
//  environment, so a measured height is exactly the height the displayed row takes.
//

import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedNativeEntry

/// One entry of the native activity table. Entries are the table's only content: the feed's
/// spacing, header, error/retry control, empty text, tail and bottom sentinel are all entries,
/// each owning its own height, so no synthetic SwiftUI structure participates in the document.
enum ActivityFeedNativeEntry: Equatable, Identifiable {
    /// The older-history header: loading, error with retry, or "Beginning of activity".
    case header(Header)
    /// The feed's empty text, shown only when there are no rows.
    case empty(String, topSpacing: CGFloat)
    /// One activity row (a single timeline row or a tool-group card).
    case row(Row)
    /// The live tail below the rows (pending messages, live step, child-task strip).
    case tail(ActivityFeedTailPresentation, topSpacing: CGFloat)
    /// The bottom sentinel: a hairline plus the feed's closing spacing.
    case bottom(topSpacing: CGFloat)

    enum Header: Equatable {
        case loading
        case error(String)
        case beginning
    }

    struct Row: Equatable {
        let row: ActivityRow
        /// Whether a tool-group card renders expanded (single rows ignore it).
        let isExpanded: Bool
        /// Whether the row animates its fade-in (following, first appearance).
        let fade: Bool
        /// The entry's top spacing: 12 before the feed's first content, 20 otherwise.
        let topSpacing: CGFloat
    }

    var id: String {
        switch self {
        case .header: "activity-feed-header"
        case .empty: "activity-feed-empty"
        case .row(let row): row.row.id
        case .tail: "activity-feed-tail"
        case .bottom: "activity-feed-bottom"
        }
    }

    /// The entry's top spacing: 12 before the feed's first content, 20 otherwise.
    var topSpacing: CGFloat {
        switch self {
        case .header: PbRadius.Metrics.spacing12
        case .empty(_, let spacing), .tail(_, let spacing), .bottom(let spacing): spacing
        case .row(let row): row.topSpacing
        }
    }

    /// The stable semantic id of reading content: timeline rows and the live tail.
    var anchorID: String? {
        switch self {
        case .row(let row): row.row.id
        case .tail: id
        default: nil
        }
    }
}

// MARK: - ActivityFeedNativeActions

/// Stable action ownership: retained cells invoke the latest feed callbacks without rewriting the
/// hosting root. The feed's view refreshes the presentation actions on every SwiftUI update,
/// including updates whose inputs are otherwise equal; the coordinator owns `retry`, whose
/// paging state machine lives beside it.
@MainActor final class ActivityFeedNativeActions {
    var onLoadMore: (() -> Bool)?
    var onDisclosure: (String) -> Void = { _ in }
    var onSelectChildTask: (String) -> Void = { _ in }
    var retry: () -> Void = {}

    func reset() {
        onLoadMore = nil
        onDisclosure = { _ in }
        onSelectChildTask = { _ in }
        retry = {}
    }
}

// MARK: - ActivityFeedNativeRowRoot

/// Inherit public renderer inputs while retaining the hosting view's own SwiftUI runtime
/// environment, including its accessibility bridge. An opaque environment replacement copies
/// the outer host's runtime state and prevents virtual accessibility descendants from appearing.
/// Read-only contrast/accessibility settings remain supplied by each host from the system.
struct ActivityFeedNativeInheritedEnvironment: ViewModifier {
    let environment: EnvironmentValues

    func body(content: Content) -> some View {
        content
            .environment(\.font, environment.font)
            .environment(\.defaultMinListRowHeight, environment.defaultMinListRowHeight)
            .environment(\.dynamicTypeSize, environment.dynamicTypeSize)
            .environment(\.locale, environment.locale)
            .environment(\.layoutDirection, environment.layoutDirection)
            .environment(\.colorScheme, environment.colorScheme)
            .environment(\.legibilityWeight, environment.legibilityWeight)
            .environment(\.displayScale, environment.displayScale)
            .environment(\.controlSize, environment.controlSize)
            .environment(\.isEnabled, environment.isEnabled)
            .environment(\.pbReduceMotionOverride, environment.pbReduceMotionOverride)
            .environment(\.shimmerReduceMotionOverride, environment.shimmerReduceMotionOverride)
            .environment(\.openURL, environment.openURL)
    }
}

/// The one SwiftUI root each entry hosts. The root carries the feed's horizontal padding and the
/// entry's own top spacing, pins itself to the offered width, and reports its natural height —
/// the exact geometry the coordinator measures. The measurement host renders this root with no
/// height report; a realized cell's root reports every change of its own laid-out height, so
/// local SwiftUI state (a tool row's expanded toggle) can grow its row without any model change.
struct ActivityFeedNativeRowRoot: View {
    let entry: ActivityFeedNativeEntry
    let start: Date?
    let horizontalPadding: CGFloat
    let showsPromptBubble: Bool
    let environment: EnvironmentValues
    let actions: ActivityFeedNativeActions
    var availableWidth: CGFloat?
    var onHostedHeight: (@MainActor @Sendable (CGFloat) -> Void)?

    var body: some View {
        content
            .id(entry.id)
            .padding(EdgeInsets(top: entry.topSpacing, leading: horizontalPadding, bottom: 0, trailing: horizontalPadding))
            .frame(width: availableWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if let onHostedHeight { onHostedHeight(height) }
            }
            .modifier(ActivityFeedNativeInheritedEnvironment(environment: environment))
    }

    @ViewBuilder private var content: some View {
        switch entry {
        case .header(let header): headerContent(header)
        case .empty(let text, _):
            Text(text).font(.pb(.body)).foregroundStyle(Color.secondaryText)
        case .row(let row): rowContent(row)
        case .tail(let presentation, _): ActivityFeedNativeTailContent(presentation: presentation, actions: actions)
        case .bottom:
            Color.clear
                .frame(height: PbRadius.Metrics.hairlineStroke)
                .accessibilityHidden(true)
                .padding(.bottom, PbRadius.Metrics.spacing12)
        }
    }

    @ViewBuilder private func headerContent(_ header: ActivityFeedNativeEntry.Header) -> some View {
        switch header {
        case .loading:
            LoadingLabel("Loading activity…")
        case .error(let error):
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing6) {
                Text(error).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                Button("Retry older activity") { actions.retry() }.buttonStyle(.link)
            }
        case .beginning:
            Text("Beginning of activity").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
        }
    }

    @ViewBuilder private func rowContent(_ row: ActivityFeedNativeEntry.Row) -> some View {
        switch row.row {
        case .toolGroup(let group):
            ToolGroupCardView(group: group, start: start, isExpanded: row.isExpanded) {
                actions.onDisclosure(group.id)
            }
            .pbFadeIn(animate: row.fade)
        case .single(let value):
            switch value.kind {
            case .separator(let text):
                TurnSeparatorRow(text: text, timestamp: value.timestamp)
                    .pbFadeIn(animate: row.fade)
            case .item(let item):
                TimelineRow(model: TimelineRowModel(item: item, start: start, live: value.live,
                                                    showsPromptBubble: showsPromptBubble))
                    .pbFadeIn(animate: row.fade)
            }
        }
    }
}

// MARK: - ActivityFeedNativeTailContent

/// The tail's rendering, identical to the feed's established presentation: the child-task strip,
/// pending message bubbles, then the live step line.
struct ActivityFeedNativeTailContent: View {
    let presentation: ActivityFeedTailPresentation
    let actions: ActivityFeedNativeActions

    @ViewBuilder var body: some View {
        switch presentation {
        case .absent:
            EmptyView()
        case .plainText(let text):
            Text(text)
        case .standard(let standard):
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing20) {
                if let strip = standard.subTaskStrip {
                    SubTaskStripView(model: SubTaskStripModel(
                        children: strip.children.map { SubTaskEntry(task: $0.task, title: $0.title) }, start: strip.start,
                        onSelectTask: { actions.onSelectChildTask($0) }
                    ))
                }
                ForEach(standard.pendingMessages) { message in
                    PromptBubbleView(text: message.text, caption: "Pending", isPending: true)
                }
                if let line = standard.liveStep {
                    switch line.indicator {
                    case .singleDot: LiveStepLineView(text: line.text)
                    case .threeDots: LiveStepLineView(text: line.text, indicator: .threeDots)
                    }
                }
            }
        }
    }
}

// MARK: - ActivityFeedNativeCell

/// One realized native cell: a single `NSHostingView` root, pinned to the cell's width and laid
/// out to the cell's bounds. The cell carries its entry id for test and diagnosis discovery.
@MainActor final class ActivityFeedNativeCell: NSTableCellView {
    var host: NSHostingView<ActivityFeedNativeRowRoot>?
    var entryID: String?
    var onMounted: (() -> Void)?
    private var hasMounted = false

    /// An owned table cell must publish the actual hosted SwiftUI hierarchy. AppKit's
    /// default text-field-based cell discovery cannot infer virtual SwiftUI descendants.
    override func isAccessibilityElement() -> Bool {
        host != nil && entryID != "activity-feed-bottom" && !isHiddenOrHasHiddenAncestor
    }

    override func accessibilityRole() -> NSAccessibility.Role? {
        host != nil ? .cell : super.accessibilityRole()
    }

    override func accessibilityChildren() -> [Any]? {
        guard isAccessibilityElement(), let host else { return [] }
        return NSAccessibility.unignoredChildren(from: [host])
    }

    func configure(root: ActivityFeedNativeRowRoot, id: String) {
        if entryID != id {
            hasMounted = false
            host?.removeFromSuperview()
            host = nil
        }
        entryID = id
        if let host {
            host.rootView = root
        } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.autoresizingMask = [.width, .height]
            addSubview(host)
            self.host = host
        }
    }

    func measure(width: CGFloat) -> CGFloat? {
        guard width > 0, let host else { return nil }
        if host.rootView.availableWidth != width { host.rootView.availableWidth = width }
        let size = host.fittingSize
        return size.height.isFinite && size.height >= 0 ? size.height : nil
    }

    override func layout() {
        super.layout()
        host?.frame = bounds
        if window != nil, !hasMounted {
            hasMounted = true
            onMounted?()
        }
    }
}

// MARK: - ActivityFeedNativeMeasurementKey

/// The height cache key: a row's render revision, the pinned column width it was measured at,
/// the environment revision and the root-input revision (start, padding, prompt bubble) it was
/// measured under. An unchanged row under unchanged polling never remeasures.
struct ActivityFeedNativeMeasurementKey: Equatable {
    let revision: Int
    let width: CGFloat
    let environmentRevision: Int
    let rootInputsRevision: Int
}

/// The inherited environment fingerprint that can change a row's height. Reuses the Sidebar's
/// captured set: the same environment fields drive every native surface's text metrics.
typealias ActivityFeedNativeEnvironmentFingerprint = SidebarNativeEnvironmentFingerprint
