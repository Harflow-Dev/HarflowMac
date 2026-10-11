//
//  TaskRow.swift
//  PbUI
//
//  The shared task row used by Sidebar and MenuBar: status icon, title over "<repo> · <Backend>",
//  and a trailing age (or a live elapsed clock while running). The tree gutter (indent, guides,
//  disclosure chevron) is kept for Sidebar's sub-task trees; MenuBar leaves those fields at their
//  defaults. Mapping from domain types (`TaskInfo`/`TaskNode`) to this Model happens in the owning
//  VM (decision 9); this component never touches `TaskInfo` itself. The sidebar passes its
//  purely presentational `SidebarRowAppearance` (SPEC §6.1); every other consumer keeps the
//  default rendering unchanged. The one further presentation-only input is `metadataForeground`:
//  the menu bar passes the palette's `primaryText` for its rows' metadata because they sit
//  directly on the MenuBarExtra window's native material, where the shared lighter inks miss
//  the 4.5:1 floor (user-approved glass-ink amendment) — gated so the sidebar and natively
//  emphasized rows ignore it, and every default (`nil`) consumer renders byte-identically.
//

import MonitorCore
import SwiftUI

// MARK: - TaskRowModel

/// Presentation data for one row representing a task: status, title, repo and backend, plus the
/// optional tree fields Sidebar needs (indent, sub-task summary, chevron state, guides). Built by
/// a VM from `TaskInfo`/`TaskNode`/`TaskListRepository.title(_:)`.
public struct TaskRowModel: Identifiable, Equatable, Sendable {
    public let id: String
    public let backend: String
    public let title: String
    public let status: TaskStatus
    /// The repository's name (`Format.repoName`), the first part of the subtitle.
    public let repoName: String
    public let detailLabel: String?
    public let ageText: String
    /// Indentation depth for a sub-task row. `0` (default) renders flush.
    public let indent: Int
    /// An optional trailing part of the subtitle, e.g. "2 sub-tasks, 1 running".
    public let subTaskSummary: String?
    /// The task's start time, driving the ticking clock while it is running.
    public let startedAt: Date?
    /// `TaskInfo.durationSeconds`, the fallback the ticking clock uses when `startedAt` is missing —
    /// mirrors `TaskInfo.elapsed(now:)`'s own fallback chain.
    public let durationSeconds: Double?
    /// Whether this task has sub-tasks — gates the disclosure chevron.
    public let hasChildren: Bool
    /// Whether a task with children shows its descendants. Ignored when `hasChildren` is `false`.
    public let isExpanded: Bool
    /// This row's tree-guide gutter — one `MonitorCore.TreeGuide` per ancestor level plus this row's
    /// own connector; empty (default) draws no gutter.
    public let guides: [TreeGuide]

    /// Whether the task is currently running — switches the trailing area to a ticking clock.
    public var isRunning: Bool { status.isRunning }

    /// "<repo name> · <Backend>", followed by the sub-task summary when there is one. No freedom text.
    public var subtitle: String {
        var parts = [repoName, BackendStyle.displayName(backend)].filter { !$0.isEmpty }
        if let subTaskSummary { parts.append(subTaskSummary) }
        return parts.joined(separator: " · ")
    }

    /// Sidebar metadata puts the backend name immediately after its identity dot, followed by
    /// the existing repository name and optional sub-task summary. Shared rows keep `subtitle`.
    public var sidebarSubtitle: String {
        var parts = [BackendStyle.displayName(backend), repoName].filter { !$0.isEmpty }
        if let subTaskSummary { parts.append(subTaskSummary) }
        return parts.joined(separator: " · ")
    }

    /// The disclosure chevron's accessibility label, task-specific per the settled plan ("Collapse
    /// <title>" / "Expand <title>") — meaningful only when `hasChildren`.
    public var chevronAccessibilityLabel: String { (isExpanded ? "Collapse " : "Expand ") + title }
    /// The disclosure chevron's exposed expanded state.
    public var chevronAccessibilityValue: String { isExpanded ? "Expanded" : "Collapsed" }

    public init(
        id: String,
        backend: String,
        title: String,
        status: TaskStatus,
        repoName: String,
        ageText: String,
        detailLabel: String? = nil,
        indent: Int = 0,
        subTaskSummary: String? = nil,
        startedAt: Date? = nil,
        durationSeconds: Double? = nil,
        hasChildren: Bool = false,
        isExpanded: Bool = true,
        guides: [TreeGuide] = []
    ) {
        self.id = id
        self.backend = backend
        self.title = title
        self.status = status
        self.repoName = repoName
        self.detailLabel = detailLabel
        self.ageText = ageText
        self.indent = indent
        self.subTaskSummary = subTaskSummary
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        self.guides = guides
    }
}

// MARK: - SidebarRowAppearance

/// The sidebar's purely presentational row configuration (SPEC §6.1): an optional view input on the
/// shared `TaskRow`/`GroupRow`, never a `TaskRowModel` field, so model equality is untouched and
/// every consumer that passes nothing — MenuBar today — keeps byte-identical rendering.
public struct SidebarRowAppearance: Equatable, Sendable {
    /// `true` only on a duplicate workflow/shortcut alias row painted with `selectedRow`: a fill
    /// that is *not* the native selection, so `backgroundProminence` never turns `.increased` on
    /// it. The sidebar's tertiary timestamps render `secondaryText` there instead, because dark
    /// tertiary (0x909099) only reaches 4.35:1 on `selectedRow` — under the 4.5:1 floor.
    public var isSelectedFill: Bool

    /// Creates a sidebar appearance, optionally marking the duplicate alias selection fill.
    public init(isSelectedFill: Bool = false) {
        self.isSelectedFill = isSelectedFill
    }
}

// MARK: - TaskRow

/// A single task row. Dumb component — no logic beyond layout.
public struct TaskRow: View {
    public let model: TaskRowModel
    /// Invoked when the disclosure chevron is tapped (rows with `hasChildren`); `nil` when the row
    /// has no children, or on MenuBar's plain rows, which never render one.
    public let onToggleExpansion: (() -> Void)?
    /// The sidebar's presentation-only appearance (SPEC §6.1), or `nil` for the shared default
    /// rendering every other consumer relies on.
    public let sidebarAppearance: SidebarRowAppearance?
    /// Optional ink for the default rendering's metadata — subtitle, detail line, age and live
    /// clock (never the title, status icon or chevron). Presentation-only view input, not a
    /// `TaskRowModel` field, so model equality is untouched. Passed only by the menu bar, whose
    /// rows sit directly on the MenuBarExtra window's native material where the lighter shared
    /// inks miss the 4.5:1 floor (user-approved glass-ink amendment); `nil` keeps the default
    /// `secondaryText` metadata everywhere.
    ///
    /// Precedence, strongest first: a natively emphasized row (`backgroundProminence == .increased`)
    /// keeps its `onAccent` metadata; a sidebar row (`sidebarAppearance != nil`) keeps §6.1's
    /// sidebar inks regardless of this value; only the default, non-emphasized rendering honors
    /// the override.
    public let metadataForeground: Color?
    @Environment(\.backgroundProminence) private var prominence
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Creates a task row with an optional disclosure action and sidebar presentation.
    public init(
        model: TaskRowModel,
        onToggleExpansion: (() -> Void)? = nil,
        sidebarAppearance: SidebarRowAppearance? = nil,
        metadataForeground: Color? = nil
    ) {
        self.model = model
        self.onToggleExpansion = onToggleExpansion
        self.sidebarAppearance = sidebarAppearance
        self.metadataForeground = metadataForeground
    }

    /// 7 pt vertical padding in the sidebar (§6.1) over the shared 6 pt default.
    private var verticalPadding: CGFloat {
        sidebarAppearance == nil ? PbRadius.Metrics.rowPaddingVertical : PbRadius.Metrics.sidebarRowPaddingVertical
    }

    @ViewBuilder
    private var title: some View {
        // The sidebar's titles are full-contrast `primaryText` (§6.1); the default keeps no
        // explicit style so consumers inherit the surrounding foreground — the system label
        // colour, except the menu bar's own `primaryText` blanket on its glass (user-approved
        // glass-ink amendment), which is why the menu needs no title API.
        switch sidebarAppearance {
        case .some:
            Text(model.title)
                .font(.pb(.body, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(prominence == .increased ? Color.onAccent : Color.primaryText)
        case nil:
            Text(model.title).font(.pb(.body, weight: .medium)).lineLimit(1)
        }
    }

    /// The meta line: the sidebar adds the agent's identity dot beside it (§6.1).
    @ViewBuilder
    private var metaLine: some View {
        switch sidebarAppearance {
        case .some:
            HStack(spacing: PbRadius.Metrics.spacing4) {
                BackendDot(backend: model.backend)
                Text(model.sidebarSubtitle).font(.pb(.secondary)).monospacedDigit().foregroundStyle(metaColor).lineLimit(1)
            }
        case nil:
            Text(model.subtitle).font(.pb(.caption)).foregroundStyle(metaColor).lineLimit(1)
        }
    }

    /// The gated metadata ink (see `metadataForeground`): non-`nil` only in the default,
    /// non-emphasized rendering — never on the sidebar's rows and never on an `onAccent` row.
    private var defaultMetadataColor: Color? {
        guard sidebarAppearance == nil, prominence != .increased else { return nil }
        return metadataForeground
    }

    private var metaColor: Color {
        if let defaultMetadataColor { return defaultMetadataColor }
        if prominence == .increased { return Color.onAccent.opacity(0.8) }
        return Color.secondaryText
    }

    /// The trailing age/clock: tertiary in the sidebar (§6.1), except where 4.5:1 demands
    /// secondary — the alias `selectedRow` fill — or a natively emphasized row's onAccent.
    private var trailingColor: Color {
        guard sidebarAppearance != nil else { return defaultMetadataColor ?? Color.secondaryText(on: prominence) }
        if prominence == .increased { return Color.onAccent.opacity(0.8) }
        if sidebarAppearance?.isSelectedFill == true { return Color.secondaryText }
        return Color.tertiaryText
    }

    public var body: some View {
        HStack(spacing: PbRadius.Metrics.rowItemSpacing) {
            TreeGutter(guides: model.guides, columnWidth: gutterColumnWidth)
                // Continue guides through the row's vertical content padding.
                .padding(.vertical, -verticalPadding)
                // The sidebar's 20 pt guide includes the surrounding row gap.
                .padding(.trailing, sidebarAppearance != nil && !model.guides.isEmpty ? -PbRadius.Metrics.rowItemSpacing : PbRadius.Metrics.zero)
            StatusIcon(status: model.status, size: iconSize)
            VStack(alignment: .leading, spacing: PbRadius.Metrics.rowLineSpacing) {
                title
                if let detail = model.detailLabel {
                    Text(detail).font(.pb(sidebarAppearance == nil ? .caption : .secondary)).foregroundStyle(metaColor).lineLimit(1)
                }
                metaLine
            }
            Spacer(minLength: PbRadius.Metrics.spacing4)
            if model.hasChildren, let onToggleExpansion {
                Button(action: onToggleExpansion) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(model.isExpanded ? 90 : 0))
                        .animation(PbMotion.disclosure(reduceMotion: reduceMotion), value: model.isExpanded)
                        .font(.pb(.caption, weight: .semibold))
                        .foregroundStyle(Color.secondaryText(on: prominence))
                        .frame(width: PbRadius.Metrics.rowChevronFrame, height: PbRadius.Metrics.rowChevronFrame)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.chevronAccessibilityLabel)
                .accessibilityValue(model.chevronAccessibilityValue)
            }
            if model.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Mirrors `TaskInfo.elapsed(now:)`'s own fallback: `startedAt` first, else the
                    // recorded `durationSeconds` (a running task with a duration but no start time).
                    let elapsed = model.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? model.durationSeconds
                    Text(Format.clock(elapsed))
                        .font(.pb(sidebarAppearance == nil ? .caption : .secondary))
                        .monospacedDigit()
                        .foregroundStyle(trailingColor)
                }
            } else {
                // The sidebar's ages render tabular digits (§6.1); the default keeps its exact
                // previous styling for every other consumer.
                switch sidebarAppearance {
                case .some:
                    Text(model.ageText).font(.pb(.secondary)).monospacedDigit().foregroundStyle(trailingColor)
                case nil:
                    Text(model.ageText).font(.pb(.caption)).foregroundStyle(trailingColor)
                }
            }
        }
        .padding(.vertical, verticalPadding)
    }

    private var gutterColumnWidth: CGFloat {
        sidebarAppearance == nil ? PbRadius.Metrics.treeGutterColumnWidth : PbRadius.Metrics.sidebarChildGuideWidth
    }

    private var iconSize: CGFloat {
        sidebarAppearance == nil ? PbRadius.Metrics.statusIconSize : PbRadius.Metrics.sidebarStatusIconSize
    }
}

// MARK: - TreeGutter

/// Decorative ancestor guides keep children indented while root rows stay flush.
/// The disclosure control lives on the trailing side of TaskRow, before its clock.
private struct TreeGutter: View {
    let guides: [TreeGuide]
    let columnWidth: CGFloat

    init(guides: [TreeGuide], columnWidth: CGFloat = PbRadius.Metrics.treeGutterColumnWidth) {
        self.guides = guides
        self.columnWidth = columnWidth
    }

    var body: some View {
        if !guides.isEmpty {
            HStack(spacing: PbRadius.Metrics.zero) {
                ForEach(Array(guides.enumerated()), id: \.offset) { index, guide in
                    if index == guides.count - 1 {
                        ownColumn(guide)
                    } else {
                        ancestorColumn(guide)
                    }
                }
            }
        }
    }

    /// A pure ancestor column: a continuation line, or nothing.
    private func ancestorColumn(_ guide: TreeGuide?) -> some View {
        ZStack {
            if guide == .continuation {
                Rectangle().fill(Color.hairline).frame(width: PbRadius.Metrics.hairlineStroke)
            }
        }
        .frame(width: columnWidth)
        .accessibilityHidden(true)
    }

    /// This row's own column draws the connector's vertical and horizontal stubs.
    @ViewBuilder
    private func ownColumn(_ guide: TreeGuide?) -> some View {
        ZStack {
            if let guide {
                VStack(spacing: PbRadius.Metrics.zero) {
                    Rectangle().fill(Color.hairline).frame(width: PbRadius.Metrics.hairlineStroke)
                    Rectangle().fill(guide == .branch ? Color.hairline : Color.clear).frame(width: PbRadius.Metrics.hairlineStroke)
                }
                .accessibilityHidden(true)
                HStack(spacing: PbRadius.Metrics.zero) {
                    Spacer(minLength: PbRadius.Metrics.zero)
                    Rectangle().fill(Color.hairline).frame(width: columnWidth / 2, height: PbRadius.Metrics.hairlineStroke)
                }
                .accessibilityHidden(true)
            }
        }
        .frame(width: columnWidth)
    }
}

#if DEBUG
#Preview("Plain - light") {
    TaskRowPlainPreview().preferredColorScheme(.light)
}

#Preview("Plain - dark") {
    TaskRowPlainPreview().preferredColorScheme(.dark)
}

private struct TaskRowPlainPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            TaskRow(model: TaskRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", status: .running, repoName: "repo", ageText: "",
                startedAt: .now.addingTimeInterval(-42)
            ))
            TaskRow(model: TaskRowModel(id: "def456", backend: "codex", title: "Refactor the parser", status: .completed, repoName: "repo", ageText: "3h"))
            TaskRow(model: TaskRowModel(id: "ghi789", backend: "vibe", title: "Bump dependencies", status: .failed, repoName: "app", ageText: "1d"))
            TaskRow(model: TaskRowModel(id: "jkl012", backend: "opencode", title: "Draft release notes", status: .cancelled, repoName: "app", ageText: "2d"))
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.formPreviewWidth)
        .background(Color.sidebarBG)
    }
}

/// A three-level tree, expanded: root → child A (with its own child) and child B.
#Preview("Tree - expanded - light") {
    TaskRowTreePreview(collapsed: false).preferredColorScheme(.light)
}

#Preview("Tree - expanded - dark") {
    TaskRowTreePreview(collapsed: false).preferredColorScheme(.dark)
}

/// The same tree with the root collapsed: descendants hidden, subtitle shows the subtree summary.
#Preview("Tree - collapsed - light") {
    TaskRowTreePreview(collapsed: true).preferredColorScheme(.light)
}

#Preview("Tree - collapsed - dark") {
    TaskRowTreePreview(collapsed: true).preferredColorScheme(.dark)
}

private struct TaskRowTreePreview: View {
    let collapsed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            TaskRow(model: TaskRowModel(
                id: "root", backend: "claude", title: "Ship the release", status: .running, repoName: "repo", ageText: "",
                subTaskSummary: collapsed ? "3 sub-tasks, 2 running" : "3 sub-tasks", startedAt: .now.addingTimeInterval(-90),
                hasChildren: true, isExpanded: !collapsed, guides: []
            )) {}
            if !collapsed {
                TaskRow(model: TaskRowModel(
                    id: "childA", backend: "codex", title: "Draft the changelog", status: .running, repoName: "repo", ageText: "",
                    indent: 1, subTaskSummary: "1 sub-task", startedAt: .now.addingTimeInterval(-40),
                    hasChildren: true, isExpanded: true, guides: [.branch]
                )) {}
                TaskRow(model: TaskRowModel(
                    id: "grandchild", backend: "vibe", title: "Proofread", status: .completed, repoName: "repo", ageText: "1m",
                    indent: 2, guides: [.continuation, .last]
                ))
                TaskRow(model: TaskRowModel(
                    id: "childB", backend: "opencode", title: "Tag the build", status: .completed, repoName: "repo", ageText: "2m",
                    indent: 1, guides: [.last]
                ))
            }
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
        .background(Color.sidebarBG)
    }
}

/// The sidebar's rows (§6.1): 15 pt glyph, dot meta line, tertiary age, 7 pt padding.
#Preview("Sidebar - light") {
    TaskRowSidebarPreview(selectedFill: false).preferredColorScheme(.light)
}

#Preview("Sidebar - dark") {
    TaskRowSidebarPreview(selectedFill: false).preferredColorScheme(.dark)
}

/// A duplicate alias row on its `selectedRow` fill — where tertiary would miss 4.5:1, so the age
/// renders secondary.
#Preview("Sidebar selected fill - light") {
    TaskRowSidebarPreview(selectedFill: true).preferredColorScheme(.light)
}

#Preview("Sidebar selected fill - dark") {
    TaskRowSidebarPreview(selectedFill: true).preferredColorScheme(.dark)
}

/// The sidebar's tree with Reduce Motion — the chevron holds still instead of rotating.
#Preview("Sidebar - Reduce Motion") {
    TaskRowSidebarPreview(selectedFill: false)
        .preferredColorScheme(.dark)
        .environment(\.pbReduceMotionOverride, true)
}

private struct TaskRowSidebarPreview: View {
    var selectedFill: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            TaskRow(
                model: TaskRowModel(
                    id: "abc123", backend: "claude", title: "Fix the login bug", status: .running, repoName: "repo",
                    ageText: "", startedAt: .now.addingTimeInterval(-42)
                ),
                sidebarAppearance: SidebarRowAppearance(isSelectedFill: selectedFill)
            )
            TaskRow(
                model: TaskRowModel(
                    id: "def456", backend: "codex", title: "Refactor the parser", status: .completed,
                    repoName: "repo", ageText: "3h", hasChildren: true, isExpanded: false
                ),
                onToggleExpansion: {},
                sidebarAppearance: SidebarRowAppearance(isSelectedFill: selectedFill)
            )
            TaskRow(
                model: TaskRowModel(
                    id: "ghi789", backend: "vibe", title: "Proofread", status: .failed, repoName: "app",
                    ageText: "2d", indent: 1, guides: [.last]
                ),
                sidebarAppearance: SidebarRowAppearance(isSelectedFill: selectedFill)
            )
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.activityPreviewWidth)
        .background(selectedFill ? Color.selectedRow : Color.sidebarBG)
    }
}

/// The menu bar's rows on native material (user-approved glass ink): `primaryText` metadata —
/// subtitle, detail, age, live clock — with the title inheriting the menu's own `primaryText`
/// blanket, because the shared lighter inks miss the 4.5:1 floor on the MenuBarExtra window's
/// glass. The background is the native material, not a fabricated flat glass colour.
#Preview("Menu glass ink - light") {
    TaskRowMenuGlassPreview().preferredColorScheme(.light)
}

#Preview("Menu glass ink - dark") {
    TaskRowMenuGlassPreview().preferredColorScheme(.dark)
}

private struct TaskRowMenuGlassPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            TaskRow(
                model: TaskRowModel(
                    id: "abc123", backend: "claude", title: "Fix the login bug", status: .running,
                    repoName: "repo", ageText: "", startedAt: .now.addingTimeInterval(-42)
                ),
                metadataForeground: .primaryText
            )
            .foregroundStyle(Color.primaryText)
            TaskRow(
                model: TaskRowModel(
                    id: "def456", backend: "codex", title: "Refactor the parser", status: .completed,
                    repoName: "repo", ageText: "3h", detailLabel: "Draft the migration plan"
                ),
                metadataForeground: .primaryText
            )
            .foregroundStyle(Color.primaryText)
        }
        .padding(PbRadius.Metrics.spacing16)
        .frame(width: PbRadius.Metrics.formPreviewWidth)
        .background(.ultraThinMaterial)
    }
}
#endif
