//
//  TaskRow.swift
//  PbUI
//
//  The shared task row used by Sidebar and MenuBar: status icon, title over "<repo> · <Backend>",
//  and a trailing age (or a live elapsed clock while running). The tree gutter (indent, guides,
//  disclosure chevron) is kept for Sidebar's sub-task trees; MenuBar leaves those fields at their
//  defaults. Mapping from domain types (`TaskInfo`/`TaskNode`) to this Model happens in the owning
//  VM (decision 9); this component never touches `TaskInfo` itself.
//

import MonitorCore
import SwiftUI

// MARK: - TaskRowModel

/// Presentation data for one row representing a task: status, title, repo and backend, plus the
/// optional tree fields Sidebar needs (indent, sub-task summary, chevron state, guides). Built by
/// a VM from `TaskInfo`/`TaskNode`/`TaskListRepository.title(_:)`.
public struct TaskRowModel: Identifiable, Equatable {
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

// MARK: - TaskRow

/// A single task row. Dumb component — no logic beyond layout.
public struct TaskRow: View {
    public let model: TaskRowModel
    /// Invoked when the disclosure chevron is tapped (rows with `hasChildren`); `nil` when the row
    /// has no children, or on MenuBar's plain rows, which never render one.
    public let onToggleExpansion: (() -> Void)?
    @Environment(\.backgroundProminence) private var prominence

    public init(model: TaskRowModel, onToggleExpansion: (() -> Void)? = nil) {
        self.model = model
        self.onToggleExpansion = onToggleExpansion
    }

    public var body: some View {
        HStack(spacing: 8) {
            TreeGutter(model: model, onToggleExpansion: onToggleExpansion)
                // Continue guides through the row’s vertical content padding.
                .padding(.vertical, -6)
            StatusIcon(status: model.status)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title).font(.pb(.body, weight: .medium)).lineLimit(1)
                if let detail = model.detailLabel {
                    Text(detail).font(.pb(.caption)).foregroundStyle(Color.secondaryText(on: prominence)).lineLimit(1)
                }
                Text(model.subtitle).font(.pb(.caption)).foregroundStyle(Color.secondaryText(on: prominence)).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.isRunning {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Mirrors `TaskInfo.elapsed(now:)`'s own fallback: `startedAt` first, else the
                    // recorded `durationSeconds` (a running task with a duration but no start time).
                    let elapsed = model.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? model.durationSeconds
                    Text(Format.clock(elapsed))
                        .font(.pb(.caption))
                        .monospacedDigit()
                        .foregroundStyle(Color.secondaryText(on: prominence))
                }
            } else {
                Text(model.ageText).font(.pb(.caption)).foregroundStyle(Color.secondaryText(on: prominence))
            }
        }
        .padding(.vertical, 6)
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
#Preview("Plain - light") {
    TaskRowPlainPreview().preferredColorScheme(.light)
}

#Preview("Plain - dark") {
    TaskRowPlainPreview().preferredColorScheme(.dark)
}

private struct TaskRowPlainPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TaskRow(model: TaskRowModel(
                id: "abc123", backend: "claude", title: "Fix the login bug", status: .running, repoName: "repo", ageText: "",
                startedAt: .now.addingTimeInterval(-42)
            ))
            TaskRow(model: TaskRowModel(id: "def456", backend: "codex", title: "Refactor the parser", status: .completed, repoName: "repo", ageText: "3h"))
            TaskRow(model: TaskRowModel(id: "ghi789", backend: "vibe", title: "Bump dependencies", status: .failed, repoName: "app", ageText: "1d"))
            TaskRow(model: TaskRowModel(id: "jkl012", backend: "opencode", title: "Draft release notes", status: .cancelled, repoName: "app", ageText: "2d"))
        }
        .padding()
        .frame(width: 300)
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
        VStack(alignment: .leading, spacing: 4) {
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
        .padding()
        .frame(width: 320)
        .background(Color.sidebarBG)
    }
}
#endif
