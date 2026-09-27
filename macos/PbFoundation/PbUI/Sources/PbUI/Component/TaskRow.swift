//
//  TaskRow.swift
//  PbUI
//
//  A shared row model added in Phase 4a (per the phase-4 brief: "If MenuBar and Sidebar would
//  share a row model, put it in PbUI now"). Originally rendered exactly the "recent" row the old
//  `MenuBarView.swift` inlined (backend badge, title, status label, age) — the same shape
//  `SidebarView` is expected to need for its own rows once Sidebar migrates. Mapping from domain
//  types (`TaskInfo`/`TaskNode`) to this Model happens in the owning VM (decision 9); this
//  component never touches `TaskInfo` itself.
//
//  Phase 4b (Sidebar migration): the old `SidebarView.swift`'s own `TaskRow` is a richer row than
//  the MenuBar one — indented per sub-task depth, showing a repo/sub-task-count/freedom meta line,
//  a live per-second running clock, and a terminal icon for a task with a live embedded session.
//  Rather than fork a second, near-duplicate row type, `TaskRowModel`/`TaskRow` gained the extra
//  fields below with defaults that preserve MenuBar's exact existing rendering unchanged (every
//  MenuBarFeature call site keeps compiling with no behaviour change — verified by
//  `MenuBarFeatureTests` staying green). Sidebar populates the new fields; MenuBar leaves them at
//  their defaults, which route through the original single-line body. This is the one documented
//  foundation change this dispatch made, per the phase-4 brief's "list it with the reason" rule.
//

import MonitorCore
import SwiftUI

// MARK: - TaskRowModel

/// Presentation data for one row representing a task: backend, title, status and age, plus the
/// optional richer fields Sidebar needs (indent, meta line, live session, running clock). Built by
/// a VM from `TaskInfo`/`TaskNode`/`TaskListRepository.title(_:)`.
public struct TaskRowModel: Identifiable, Equatable {
    public let id: String
    public let backend: String
    public let title: String
    public let statusLabel: String
    public let statusColor: Color
    public let ageText: String
    /// Sidebar-only: indentation depth for a sub-task row. `0` (default) renders flush, matching
    /// MenuBar's row exactly.
    public let indent: Int
    /// Sidebar-only: the "repo · N sub-tasks · freedom" line shown under the title. `nil` (default)
    /// renders MenuBar's original single-line layout.
    public let metaText: String?
    /// Sidebar-only: whether the task is currently running — switches the trailing area to a
    /// ticking clock instead of a static status/age pair. Ignored unless `metaText` is set.
    public let isRunning: Bool
    /// Sidebar-only: the task's start time, driving the ticking clock when `isRunning` is true.
    public let startedAt: Date?
    /// Sidebar-only: `TaskInfo.durationSeconds`, the fallback the ticking clock uses when
    /// `startedAt` is missing — mirrors `TaskInfo.elapsed(now:)`'s own fallback chain exactly (a
    /// running task with a recorded duration but no start time is an edge case the old code still
    /// handled, not a hypothetical one).
    public let durationSeconds: Double?
    /// Sidebar-only (Monitor piece 4): whether this task has sub-tasks — gates the disclosure
    /// chevron. `false` (default) renders no chevron, matching MenuBar's row exactly.
    public let hasChildren: Bool
    /// Sidebar-only: whether a task with children shows its descendants. Ignored when
    /// `hasChildren` is `false`. Defaults to `true` (expanded), the tree's default state.
    public let isExpanded: Bool
    /// Sidebar-only: this row's tree-guide gutter — one `MonitorCore.TreeGuide` per ancestor level
    /// plus this row's own connector; empty (default) draws no gutter, matching MenuBar's row and a
    /// root row (indent 0) alike.
    public let guides: [TreeGuide]

    /// The disclosure chevron's accessibility label, task-specific per the settled plan ("Collapse
    /// <title>" / "Expand <title>") — meaningful only when `hasChildren`.
    public var chevronAccessibilityLabel: String { (isExpanded ? "Collapse " : "Expand ") + title }
    /// The disclosure chevron's exposed expanded state.
    public var chevronAccessibilityValue: String { isExpanded ? "Expanded" : "Collapsed" }

    public init(
        id: String,
        backend: String,
        title: String,
        statusLabel: String,
        statusColor: Color,
        ageText: String,
        indent: Int = 0,
        metaText: String? = nil,
        isRunning: Bool = false,
        startedAt: Date? = nil,
        durationSeconds: Double? = nil,
        hasChildren: Bool = false,
        isExpanded: Bool = true,
        guides: [TreeGuide] = []
    ) {
        self.id = id
        self.backend = backend
        self.title = title
        self.statusLabel = statusLabel
        self.statusColor = statusColor
        self.ageText = ageText
        self.indent = indent
        self.metaText = metaText
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        self.guides = guides
    }
}

// MARK: - TaskRow

/// A single task row. Dumb component — no logic beyond layout. Renders MenuBar's original
/// single-line shape when `model.metaText == nil`, or Sidebar's richer indented shape (meta line,
/// terminal icon, live clock) when it is set — see the file header for why one component covers
/// both.
public struct TaskRow: View {
    public let model: TaskRowModel
    /// Invoked when the disclosure chevron is tapped (rows with `hasChildren`); `nil` when the row
    /// has no children, or on MenuBar's plain rows, which never render one.
    public let onToggleExpansion: (() -> Void)?

    public init(model: TaskRowModel, onToggleExpansion: (() -> Void)? = nil) {
        self.model = model
        self.onToggleExpansion = onToggleExpansion
    }

    public var body: some View {
        if let metaText = model.metaText {
            richBody(metaText)
        } else {
            simpleBody
        }
    }

    /// MenuBar's original, unchanged layout.
    private var simpleBody: some View {
        HStack(spacing: 8) {
            BackendBadge(backend: model.backend, size: 18)
            Text(model.title).font(.pb(.body)).lineLimit(1)
            Spacer()
            Text(model.statusLabel).font(.pb(.caption)).foregroundStyle(model.statusColor)
            Text(model.ageText).font(.pb(.caption)).foregroundStyle(.secondary)
        }
    }

    /// Sidebar's original layout, ported verbatim from `SidebarView.swift`'s old `TaskRow`, plus the
    /// tree-guide gutter and disclosure chevron (Monitor piece 4).
    private func richBody(_ metaText: String) -> some View {
        HStack(spacing: 8) {
            TreeGutter(model: model, onToggleExpansion: onToggleExpansion)
            BackendBadge(backend: model.backend, size: model.indent == 0 ? 20 : 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.pb(.body, weight: model.indent == 0 ? .medium : .regular)).lineLimit(1)
                Text(metaText).font(.pb(.caption)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isRunning {
                Circle().fill(Color.runningFG).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Mirrors `TaskInfo.elapsed(now:)`'s own fallback: `startedAt` first, else the
                    // recorded `durationSeconds` (a running task with a duration but no start time).
                    let elapsed = model.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? model.durationSeconds
                    Text(Format.clock(elapsed))
                        .font(.pb(.caption))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.statusLabel).font(.pb(.caption, weight: .medium)).foregroundStyle(model.statusColor)
                    Text(model.ageText).font(.pb(.caption)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - TreeGutter

/// The sidebar tree's indent gutter: one 16pt column per ancestor level (a hairline continuation
/// line, or blank), followed by this row's own connector column — which, on a row with children,
/// overlays the disclosure chevron in place of a static connector glyph. Decorative lines are
/// `accessibilityHidden`; the chevron button is a real, independently-focusable control with its
/// own hit area, so tapping it toggles expansion without selecting the row.
private struct TreeGutter: View {
    let model: TaskRowModel
    let onToggleExpansion: (() -> Void)?

    private static let columnWidth: CGFloat = 16

    /// The gutter's own column list: `model.guides` as-is, except a root row (`guides` empty) that
    /// has children still needs exactly one column to host its chevron.
    private var columns: [TreeGuide?] {
        model.guides.isEmpty ? (model.hasChildren ? [nil] : []) : model.guides
    }

    var body: some View {
        if !columns.isEmpty {
            HStack(spacing: 0) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, guide in
                    if index == columns.count - 1 {
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
                Rectangle().fill(Color.hairline).frame(width: 1)
            }
        }
        .frame(width: Self.columnWidth)
        .accessibilityHidden(true)
    }

    /// This row's own column: the connector's vertical/horizontal stubs, with the chevron button
    /// overlaid when the row has children.
    @ViewBuilder
    private func ownColumn(_ guide: TreeGuide?) -> some View {
        ZStack {
            if let guide {
                VStack(spacing: 0) {
                    Rectangle().fill(Color.hairline).frame(width: 1)
                    Rectangle().fill(guide == .branch ? Color.hairline : Color.clear).frame(width: 1)
                }
                .accessibilityHidden(true)
                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle().fill(Color.hairline).frame(width: Self.columnWidth / 2, height: 1)
                }
                .accessibilityHidden(true)
            }
            if model.hasChildren, let onToggleExpansion {
                Button(action: onToggleExpansion) {
                    Image(systemName: model.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.pb(.caption, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: Self.columnWidth, height: Self.columnWidth)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(model.chevronAccessibilityLabel)
                .accessibilityValue(model.chevronAccessibilityValue)
            }
        }
        .frame(width: Self.columnWidth)
    }
}

#if DEBUG
#Preview {
    TaskRow(model: TaskRowModel(id: "abc123", backend: "claude", title: "Fix the login bug", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h"))
        .padding()
        .frame(width: 280)
}

#Preview("Sidebar shape") {
    VStack(alignment: .leading, spacing: 8) {
        TaskRow(model: TaskRowModel(
            id: "abc123", backend: "claude", title: "Fix the login bug", statusLabel: "Running", statusColor: .runningFG, ageText: "",
            indent: 0, metaText: "~/repo · 2 sub-tasks · write_in_repo", isRunning: true, startedAt: .now.addingTimeInterval(-42)
        ))
        TaskRow(model: TaskRowModel(
            id: "def456", backend: "codex", title: "Sub-task", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h",
            indent: 1, metaText: "~/repo", isRunning: false, startedAt: nil
        ))
    }
    .padding()
    .frame(width: 320)
}

/// A three-level tree, expanded: root → child A (with its own child) and child B — Monitor piece 4.
#Preview("Tree - expanded") {
    VStack(alignment: .leading, spacing: 4) {
        TaskRow(model: TaskRowModel(
            id: "root", backend: "claude", title: "Ship the release", statusLabel: "Running", statusColor: .runningFG, ageText: "",
            indent: 0, metaText: "~/repo · 3 sub-tasks · write_in_repo", isRunning: true, startedAt: .now.addingTimeInterval(-90),
            hasChildren: true, isExpanded: true, guides: []
        )) {}
        TaskRow(model: TaskRowModel(
            id: "childA", backend: "codex", title: "Draft the changelog", statusLabel: "Running", statusColor: .runningFG, ageText: "",
            indent: 1, metaText: "~/repo · 1 sub-task", isRunning: true, startedAt: .now.addingTimeInterval(-40),
            hasChildren: true, isExpanded: true, guides: [.branch]
        )) {}
        TaskRow(model: TaskRowModel(
            id: "grandchild", backend: "vibe", title: "Proofread", statusLabel: "Done", statusColor: .doneGreen, ageText: "1m",
            indent: 2, metaText: "~/repo", isRunning: false, startedAt: nil,
            hasChildren: false, isExpanded: true, guides: [.continuation, .last]
        ))
        TaskRow(model: TaskRowModel(
            id: "childB", backend: "opencode", title: "Tag the build", statusLabel: "Done", statusColor: .doneGreen, ageText: "2m",
            indent: 1, metaText: "~/repo", isRunning: false, startedAt: nil,
            hasChildren: false, isExpanded: true, guides: [.last]
        ))
    }
    .padding()
    .frame(width: 320)
}

/// The same tree with the root collapsed: descendants hidden, meta line shows the subtree summary.
#Preview("Tree - collapsed") {
    TaskRow(model: TaskRowModel(
        id: "root", backend: "claude", title: "Ship the release", statusLabel: "Running", statusColor: .runningFG, ageText: "",
        indent: 0, metaText: "~/repo · 3 sub-tasks, 2 running · write_in_repo", isRunning: true, startedAt: .now.addingTimeInterval(-90),
        hasChildren: true, isExpanded: false, guides: []
    )) {}
    .padding()
    .frame(width: 320)
}
#endif
