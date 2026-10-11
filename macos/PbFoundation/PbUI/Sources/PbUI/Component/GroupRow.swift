import MonitorCore
import SwiftUI

// MARK: - GroupRow

/// A parallel run as one row: overlapping backend dots, the group's name over "Parallel run · N of
/// M finished", a thin progress bar while any member is running, and a spinner alongside it. Takes only a plain
/// `ParallelGroup` value and never reads `AppModel`, so it qualifies for the shared component layer.
public struct GroupRow: View {
    public let group: ParallelGroup
    private let conversations: [Conversation]
    /// The sidebar's presentation-only appearance (SPEC §6.1), or `nil` for the shared default
    /// rendering every other consumer (MenuBar today) relies on.
    private let sidebarAppearance: SidebarRowAppearance?
    /// Optional ink for the default rendering's subtitle only (never the title, backend dots,
    /// progress bar or spinner). Presentation-only view input, not a model field, so it changes
    /// no equality. Passed only by the menu bar, whose rows sit directly on the MenuBarExtra
    /// window's native material where the lighter shared inks miss the 4.5:1 floor
    /// (user-approved glass-ink amendment); `nil` keeps the default subtitle ink everywhere.
    ///
    /// Precedence, strongest first: a natively emphasized row (`backgroundProminence == .increased`)
    /// keeps its `onAccent` subtitle; a sidebar row (`sidebarAppearance != nil`) keeps §6.1's
    /// sidebar inks regardless of this value; only the default, non-emphasized rendering honors
    /// the override.
    private let metadataForeground: Color?
    @Environment(\.backgroundProminence) private var prominence

    /// - Parameters:
    ///   - group: the parallel group to render.
    ///   - conversations: the screen's actual-session projection; defaults to the group's own.
    ///   - sidebarAppearance: the sidebar's presentation-only configuration, or `nil` for the
    ///     unchanged default rendering.
    ///   - metadataForeground: optional ink for the default rendering's subtitle only; `nil`
    ///     keeps the unchanged default.
    public init(
        group: ParallelGroup,
        conversations: [Conversation]? = nil,
        sidebarAppearance: SidebarRowAppearance? = nil,
        metadataForeground: Color? = nil
    ) {
        self.group = group
        self.conversations = conversations ?? group.conversations
        self.sidebarAppearance = sidebarAppearance
        self.metadataForeground = metadataForeground
    }

    private var total: Int { conversations.count }
    private var doneCount: Int { Self.finishedCount(of: conversations.map(\.current.status)) }

    /// Terminal members — done, failed, cancelled, timed out — all count as "finished": the count
    /// says "this member has settled", never "succeeded" (SPEC §1.6 keeps the honest word).
    public nonisolated static func finishedCount(of statuses: [TaskStatus]) -> Int {
        statuses.filter(\.isTerminal).count
    }

    /// "Parallel run · N of M finished" — or, for a group of one, "Group · <status>", since a
    /// single member is not a parallel run.
    public nonisolated static func subtitle(finished: Int, total: Int, singleMemberStatus: TaskStatus? = nil) -> String {
        if total == 1, let singleMemberStatus { return "Group · \(singleMemberStatus.label)" }
        return "Parallel run · \(finished) of \(total) finished"
    }

    /// The fraction of members that finished, clamped to 0...1; 0 for an empty group.
    public nonisolated static func progress(finished: Int, total: Int) -> Double {
        total > 0 ? min(1, max(0, Double(finished) / Double(total))) : 0
    }

    /// The bar only tracks a run in flight; a finished group shows none.
    public nonisolated static func showsProgress(anyRunning: Bool) -> Bool {
        anyRunning
    }

    @ViewBuilder
    private var title: some View {
        // The sidebar's title is full-contrast `primaryText` (§6.1); the default keeps no
        // explicit style so consumers inherit the surrounding foreground — the system label
        // colour, except the menu bar's own `primaryText` blanket on its glass (user-approved
        // glass-ink amendment), which is why the menu needs no title API.
        switch sidebarAppearance {
        case .some:
            Text(group.name)
.font(.pb(.body, weight: .medium))
.lineLimit(1)
                .foregroundStyle(prominence == .increased ? Color.onAccent : Color.primaryText)
        case nil:
            Text(group.name).font(.pb(.body, weight: .medium)).lineLimit(1)
        }
    }

    /// The in-flight bar: the sidebar's 3 pt strip in `runningFG` (§6.1); the shared default keeps
    /// the system mini linear progress view.
    @ViewBuilder
    private var progress: some View {
        switch sidebarAppearance {
        case .some:
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(prominence == .increased ? Color.sidebarSelectedProgressTrack : Color.pillFill)
                    Capsule()
                        .fill(prominence == .increased ? Color.onAccent : Color.runningFG)
                        .frame(width: proxy.size.width * Self.progress(finished: doneCount, total: total))
                }
            }
            .frame(height: PbRadius.Metrics.sidebarProgressHeight)
            .accessibilityHidden(true)
        case nil:
            ProgressView(value: Self.progress(finished: doneCount, total: total))
                .progressViewStyle(.linear)
                .controlSize(.mini)
                .tint(prominence == .increased ? Color.onAccent : Color.runningFG)
        }
    }

    public var body: some View {
        HStack(spacing: PbRadius.Metrics.rowItemSpacing) {
            BackendDotStack(backends: conversations.prefix(3).map(\.first.backend))
            VStack(alignment: .leading, spacing: PbRadius.Metrics.rowLineSpacing) {
                title
                subtitleText
                if Self.showsProgress(anyRunning: group.anyRunning) {
                    progress
                }
            }
            Spacer(minLength: PbRadius.Metrics.spacing4)
            if group.anyRunning { RunningSpinner(tint: prominence == .increased ? .onAccent : nil) }
        }
        .padding(.vertical, sidebarAppearance == nil ? PbRadius.Metrics.rowPaddingVertical : PbRadius.Metrics.sidebarRowPaddingVertical)
    }

    /// The gated subtitle ink (see `metadataForeground`): non-`nil` only in the default,
    /// non-emphasized rendering — never on the sidebar's rows and never on an `onAccent` row.
    private var defaultMetadataColor: Color? {
        guard sidebarAppearance == nil, prominence != .increased else { return nil }
        return metadataForeground
    }

    @ViewBuilder
    private var subtitleText: some View {
        let text = Text(Self.subtitle(finished: doneCount, total: total, singleMemberStatus: conversations.first?.current.status))
            .font(.pb(sidebarAppearance == nil ? .caption : .secondary))
            .foregroundStyle(defaultMetadataColor ?? Color.secondaryText(on: prominence))
            .lineLimit(1)
        if sidebarAppearance == nil { text } else { text.monospacedDigit() }
    }
}

#if DEBUG
#Preview("GroupRow - light") {
    GroupRowPreview().preferredColorScheme(.light)
}

#Preview("GroupRow - dark") {
    GroupRowPreview().preferredColorScheme(.dark)
}

#Preview("GroupRow finished - light") {
    GroupRowPreview(finished: true).preferredColorScheme(.light)
}

#Preview("GroupRow finished - dark") {
    GroupRowPreview(finished: true).preferredColorScheme(.dark)
}

/// The sidebar's group row (§6.1): full-contrast title and the 3 pt `runningFG` strip.
#Preview("GroupRow sidebar - light") {
    GroupRowSidebarPreview().preferredColorScheme(.light)
}

#Preview("GroupRow sidebar - dark") {
    GroupRowSidebarPreview().preferredColorScheme(.dark)
}

#Preview("GroupRow sidebar emphasized - light") {
    GroupRowSidebarPreview(emphasized: true)
        .preferredColorScheme(.light)
        .environment(\.backgroundProminence, .increased)
        .environment(\.pbReduceMotionOverride, true)
}

#Preview("GroupRow sidebar emphasized - dark") {
    GroupRowSidebarPreview(emphasized: true)
        .preferredColorScheme(.dark)
        .environment(\.backgroundProminence, .increased)
        .environment(\.pbReduceMotionOverride, true)
}

/// A settled group in the sidebar — no progress strip, no spinner, the honest "finished" count.
#Preview("GroupRow sidebar finished - light") {
    GroupRowSidebarPreview(finished: true).preferredColorScheme(.light)
}

#Preview("GroupRow sidebar finished - dark") {
    GroupRowSidebarPreview(finished: true).preferredColorScheme(.dark)
}

/// The sidebar's group row under Reduce Motion — the spinner holds still.
#Preview("GroupRow sidebar - Reduce Motion") {
    GroupRowSidebarPreview()
        .preferredColorScheme(.dark)
        .environment(\.pbReduceMotionOverride, true)
}

private struct GroupRowSidebarPreview: View {
    var finished = false
    var emphasized = false

    var body: some View {
        // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
        // so the preview goes through the same public `Lineage.sections` entry point the app uses.
        let tasks = [
            TaskInfo(.object([
                "task_id": .string("abc123"), "backend": .string("claude"), "status": .string(finished ? "failed" : "running"),
                "group": .string("release-notes")
            ]))!,
            TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("cancelled"), "group": .string("release-notes")]))!
        ]
        GroupRow(group: Lineage.sections(tasks).parallel.first!, sidebarAppearance: SidebarRowAppearance())
            .padding(PbRadius.Metrics.spacing16)
            .frame(width: PbRadius.Metrics.groupPreviewWidth)
            .background(emphasized ? Color.accentFill : Color.sidebarBG)
    }
}

private struct GroupRowPreview: View {
    var finished = false

    var body: some View {
        // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
        // so the preview goes through the same public `Lineage.sections` entry point the app uses.
        let tasks = [
            TaskInfo(.object([
                "task_id": .string("abc123"), "backend": .string("claude"), "status": .string(finished ? "completed" : "running"),
                "group": .string("release-notes")
            ]))!,
            TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!
        ]
        GroupRow(group: Lineage.sections(tasks).parallel.first!)
            .padding(PbRadius.Metrics.spacing16)
            .frame(width: PbRadius.Metrics.groupPreviewWidth)
            .background(Color.sidebarBG)
    }
}

/// The menu bar's group row on native material (user-approved glass ink): `primaryText` subtitle
/// with the title inheriting the menu's own `primaryText` blanket, because the shared lighter
/// inks miss the 4.5:1 floor on the MenuBarExtra window's glass. The background is the native
/// material, not a fabricated flat glass colour.
#Preview("GroupRow menu glass ink - light") {
    GroupRowMenuGlassPreview().preferredColorScheme(.light)
}

#Preview("GroupRow menu glass ink - dark") {
    GroupRowMenuGlassPreview().preferredColorScheme(.dark)
}

private struct GroupRowMenuGlassPreview: View {
    var body: some View {
        // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
        // so the preview goes through the same public `Lineage.sections` entry point the app uses.
        let tasks = [
            TaskInfo(.object([
                "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
                "group": .string("release-notes")
            ]))!,
            TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!
        ]
        GroupRow(group: Lineage.sections(tasks).parallel.first!, metadataForeground: .primaryText)
            .foregroundStyle(Color.primaryText)
            .padding(PbRadius.Metrics.spacing16)
            .frame(width: PbRadius.Metrics.groupPreviewWidth)
            .background(.ultraThinMaterial)
    }
}
#endif
