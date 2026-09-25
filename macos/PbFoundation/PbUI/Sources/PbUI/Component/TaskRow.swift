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
    /// Sidebar-only: whether a live embedded terminal session is attached to this task (shows the
    /// terminal glyph). Ignored unless `metaText` is set.
    public let hasLiveSession: Bool
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
    
    public init(
        id: String,
        backend: String,
        title: String,
        statusLabel: String,
        statusColor: Color,
        ageText: String,
        indent: Int = 0,
        metaText: String? = nil,
        hasLiveSession: Bool = false,
        isRunning: Bool = false,
        startedAt: Date? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.backend = backend
        self.title = title
        self.statusLabel = statusLabel
        self.statusColor = statusColor
        self.ageText = ageText
        self.indent = indent
        self.metaText = metaText
        self.hasLiveSession = hasLiveSession
        self.isRunning = isRunning
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
    }
}

// MARK: - TaskRow

/// A single task row. Dumb component — no logic beyond layout. Renders MenuBar's original
/// single-line shape when `model.metaText == nil`, or Sidebar's richer indented shape (meta line,
/// terminal icon, live clock) when it is set — see the file header for why one component covers
/// both.
public struct TaskRow: View {
    public let model: TaskRowModel
    
    public init(model: TaskRowModel) {
        self.model = model
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
            Text(model.title).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(model.statusLabel).font(.system(size: 10)).foregroundStyle(model.statusColor)
            Text(model.ageText).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    
    /// Sidebar's original layout, ported verbatim from `SidebarView.swift`'s old `TaskRow`.
    private func richBody(_ metaText: String) -> some View {
        HStack(spacing: 8) {
            BackendBadge(backend: model.backend, size: model.indent == 0 ? 20 : 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title).font(.system(size: 12, weight: model.indent == 0 ? .medium : .regular)).lineLimit(1)
                Text(metaText).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.hasLiveSession {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Color(hex: 0x8A4B00))
            }
            if model.isRunning {
                Circle().fill(Color.runningFG).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    // Mirrors `TaskInfo.elapsed(now:)`'s own fallback: `startedAt` first, else the
                    // recorded `durationSeconds` (a running task with a duration but no start time).
                    let elapsed = model.startedAt.map { max(0, context.date.timeIntervalSince($0)) } ?? model.durationSeconds
                    Text(Format.clock(elapsed))
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(model.statusLabel).font(.system(size: 10, weight: .medium)).foregroundStyle(model.statusColor)
                    Text(model.ageText).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, CGFloat(model.indent) * 16)
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
            indent: 0, metaText: "~/repo · 2 sub-tasks · write_in_repo", hasLiveSession: true, isRunning: true, startedAt: .now.addingTimeInterval(-42)
        ))
        TaskRow(model: TaskRowModel(
            id: "def456", backend: "codex", title: "Sub-task", statusLabel: "Done", statusColor: .doneGreen, ageText: "3h",
            indent: 1, metaText: "~/repo", hasLiveSession: false, isRunning: false, startedAt: nil
        ))
    }
    .padding()
    .frame(width: 320)
}
#endif
