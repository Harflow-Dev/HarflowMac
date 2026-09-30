//
//  InspectorView.swift
//  MainWindowFeature
//
//  Ported from the app target's `InspectorView.swift`. "Now" reads the timeline's current running
//  tool; "Details"/"Enforcement" read the raw snapshot (falling back to the listing). "Files
//  changed" (git) and the "Branch" row are gone (piece 2/3 of the Monitor architecture plan — see
//  the Summary tab's "Files the agent edited" section instead).
//
//  Redesign phase 5 (settled plan D14/D17): the plain "Details" (Agent, Access, Started, Started
//  by) and the copy buttons come first; everything the old panel showed — session, lineage, limits,
//  enforcement, notices — sits in a collapsed "Technical info" disclosure. The whole inspector is
//  hidden by default (`TaskDetailView` owns that toggle).
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - InspectorModel

struct InspectorModel {
    let task: TaskInfo
    let current: TimelineItem?
    let stepCount: Int
    let activity: ActivityCounts
    let subtaskCount: Int
    let ancestors: [SubTaskEntry]
    let siblings: [SubTaskEntry]
    let detail: TaskInfo
    let hasSnapshot: Bool
    let notices: [String]
    /// What polybridge reports as enforced (`PbUI.EnforcementText.lines(_:)`, mapped in the VM from
    /// the snapshot-or-listing `detail`) — moved here from the Summary tab (item 15). Empty when
    /// nothing was reported; defaults so call sites that read a bare task (previews, older tests)
    /// keep building.
    var enforcementLines: [String] = []
    /// The parent task's title when one is recorded, else "Top-level task" (D17).
    let startedBy: String
    /// `nil` hides the "Copy resume command" button.
    let resumeCommand: String?
    let onCopyResumeCommand: () -> Void
    let onCopyTaskID: () -> Void
    let onSelectTask: (String) -> Void

    /// "What was enforced" shows only once there are lines to list or a settled snapshot carried
    /// none — never while the snapshot itself hasn't loaded (item 15 moved the section here from
    /// the Summary tab).
    var showsEnforcement: Bool {
        !enforcementLines.isEmpty || InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: hasSnapshot)
    }

    /// The "Started by" value: the parent's title when the task was started by another task.
    static func startedByText(parentTitle: String?) -> String {
        parentTitle ?? "Top-level task"
    }

    /// "Enforcement was not recorded for this task." only once a snapshot exists but carried no
    /// enforcement data — never while the snapshot itself hasn't loaded.
    static func showsEnforcementNotRecorded(detail: TaskInfo, hasSnapshot: Bool) -> Bool {
        detail.enforcement == nil && hasSnapshot
    }

    /// `notices` with repeats removed, first occurrence kept — a resumed run often reports the same
    /// environment warning once per turn.
    static func distinctNotices(_ notices: [String]) -> [String] {
        var seen: Set<String> = []
        return notices.filter { seen.insert($0).inserted }
    }
}

// MARK: - InspectorView

struct InspectorView: View {
    let model: InspectorModel?
    @State private var technicalExpanded = false

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 24) {
                    if model.task.status.isRunning { now(model) }
                    section("Details") { basics(model) }
                    if !model.notices.isEmpty { notices(model) }
                    actions(model)
                    section("Activity") {
                        Text("\(model.activity.toolCalls) tool calls · \(model.activity.edits) edits · "
                             + "\(model.activity.commands) commands · \(model.subtaskCount) sub-tasks")
                        .font(.pb(.secondary))
                    }
                    DisclosureGroup(isExpanded: $technicalExpanded) {
                        // macOS centres a DisclosureGroup's content unless it is given the full width.
                        technicalInfo(model).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        SectionLabel(text: "Technical info")
                    }
                }
                .padding(20)
            }
        }
        .background(Color.inspectorFill)
    }

    @ViewBuilder
    private func now(_ model: InspectorModel) -> some View {
        section("Now") {
            if let current = model.current, case .tool(let call, _) = current.body {
                Text(call.tool).font(.pb(.body, weight: .medium))
                Text(call.headline).font(.pb(.secondary, design: .monospaced)).foregroundStyle(Color.secondaryText).lineLimit(3)
                if let startedAt = current.at {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(Format.clock(context.date.timeIntervalSince(startedAt))) · step \(model.stepCount)")
                            .font(.pb(.caption))
                            .monospacedDigit()
                            .foregroundStyle(Color.secondaryText)
                    }
                }
            } else {
                Text("Thinking or writing").font(.pb(.body)).foregroundStyle(Color.secondaryText)
            }
        }
    }

    @ViewBuilder
    private func basics(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                detailName("Agent")
                BackendLabel(backend: model.task.backend).font(.pb(.secondary))
            }
            detailRow("Access", model.task.freedom.map { AccessLabel.text(freedom: $0) } ?? "—")
            detailRow("Started", Format.time(model.task.startedAt))
            detailRow("Started by", model.startedBy)
        }
    }

    @ViewBuilder
    private func actions(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.resumeCommand != nil {
                Button("Copy resume command", action: model.onCopyResumeCommand)
            }
            Button("Copy task ID", action: model.onCopyTaskID)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    @ViewBuilder
    private func technicalInfo(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Details") { details(model) }
            if !model.task.isRoot { lineage(model) }
            if model.showsEnforcement { section("What was enforced") { enforcement(model) } }
        }
    }

    /// "What was enforced" (Summary-tab item 15: the section moved here): the plain
    /// `PbUI.EnforcementText` sentences, plus the not-recorded note once a snapshot settled
    /// without any enforcement data.
    private func enforcement(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.enforcementLines, id: \.self) { line in
                Text(line).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            }
            if InspectorModel.showsEnforcementNotRecorded(detail: model.detail, hasSnapshot: model.hasSnapshot) {
                Text("Enforcement was not recorded for this task.")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
            }
        }
    }

    /// Notices the run reported (environment warnings, dispatch notes). They live here rather than
    /// above the activity; the header only shows a count that opens this panel.
    private func notices(_ model: InspectorModel) -> some View {
        section("Notices") {
            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Color.warningFG)
                    Text(notice).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            content()
        }
    }

    private func lineage(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            section("Lineage") {
                ForEach(Array(model.ancestors.enumerated()), id: \.element.id) { index, ancestor in
                    lineageRow(ancestor, indent: index, currentTaskID: model.task.taskID, onSelectTask: model.onSelectTask)
                }
                ForEach(model.siblings) { sibling in
                    lineageRow(sibling, indent: model.ancestors.count, currentTaskID: model.task.taskID, onSelectTask: model.onSelectTask)
                }
            }
            section("Limits from parent") {
                if let parent = model.ancestors.last {
                    limit(
                        "Freedom", model.task.freedom ?? "—",
                        "Parent is \(parent.task.freedom ?? "unknown"). polybridge refuses a sub-task that is less strict than its caller."
                    )
                }
                if let maxDepth = model.task.maxDepth {
                    let left = maxDepth - model.task.depth
                    limit(
                        "Depth", "\(model.task.depth) of \(maxDepth)",
                        left > 0
                        ? "This task can start \(left) more level\(left == 1 ? "" : "s") of sub-tasks."
                        : "This task cannot start sub-tasks of its own."
                    )
                }
                limit(
                    "Cancels with parent", "attempted",
                    "Cancelling the parent also tries to stop this task (best-effort cascade); the cancel result says what did not stop."
                )
            }
        }
    }
    
    private func lineageRow(_ entry: SubTaskEntry, indent: Int, currentTaskID: String, onSelectTask: @escaping (String) -> Void) -> some View {
        let current = entry.task.taskID == currentTaskID
        return Button {
            onSelectTask(entry.task.taskID)
        } label: {
            HStack(spacing: 6) {
                BackendLabel(backend: entry.task.backend).font(.pb(.caption))
                Text(entry.title).font(.pb(.secondary, weight: current ? .semibold : .regular)).lineLimit(1)
                Spacer()
                Text("depth \(entry.task.depth)").font(.pb(.caption)).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(indent) * 10)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
    
    private func limit(_ name: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack { Text(name).font(.pb(.secondary, weight: .medium)); Spacer(); Text(value).font(.pb(.secondary)) }
            Text(note).font(.pb(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    
    @ViewBuilder
    private func details(_ model: InspectorModel) -> some View {
        let task = model.task
        let detail = model.detail
        detailRow("Task", task.taskID)
        detailRow("Backend", [task.backend, detail.model, detail.reasoningEffort.map { "effort \($0)" }].compactMap(\.self).joined(separator: " · "))
        detailRow("Freedom", task.freedom ?? "—")
        detailRow("Started", Format.time(task.startedAt) + (task.isRoot ? " · root task" : ""))
        if let maxDepth = task.maxDepth { detailRow("Depth", "\(task.depth) of \(maxDepth)") }
        if let parent = task.spawnedBy { detailRow("Parent", parent) }
        if let root = task.rootTaskID, root != task.taskID { detailRow("Root", root) }
        if let group = task.group { detailRow("Group", group) }
        if let resumed = task.parentTaskID { detailRow("Resumed from", resumed) }
        if let session = task.sessionID { detailRow("Session", session) }
        if let detected = task.lineageDetected { detailRow("Caller found by", detected) }
        if let cost = detail.totalCostUSD { detailRow("Cost", String(format: "$%.4f", cost)) }
    }
    
    private func detailName(_ name: String) -> some View {
        Text(name).font(.pb(.secondary)).foregroundStyle(Color.secondaryText).frame(width: 84, alignment: .leading)
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            detailName(name)
            Text(value).font(.pb(.secondary)).textSelection(.enabled).lineLimit(3)
        }
    }
}

#if DEBUG
@MainActor
private func previewModel(status: String, isRoot: Bool, enforcement: Bool = true) -> InspectorModel {
    let task = TaskDetailViewModelMock.sampleTask(status: status, spawnedBy: isRoot ? nil : "parent01")
    var activity = ActivityCounts()
    activity.toolCalls = 12
    activity.edits = 2
    activity.commands = 3
    return InspectorModel(
        task: task, current: nil, stepCount: 4,
        activity: activity, subtaskCount: 1,
        ancestors: [], siblings: [], detail: task, hasSnapshot: true, notices: ["Approaching the turn limit."],
        enforcementLines: enforcement
            ? ["Restrictions enforced by the OS sandbox", "Git commit and push blocked"]
            : [],
        startedBy: InspectorModel.startedByText(parentTitle: isRoot ? nil : "Refactor the sidebar"),
        resumeCommand: "cd /repo && claude --resume abc", onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
    )
}

#Preview("Running - light") {
    InspectorView(model: previewModel(status: "running", isRoot: true))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.light)
}

#Preview("Sub-task - dark") {
    InspectorView(model: previewModel(status: "completed", isRoot: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("No enforcement recorded - light") {
    InspectorView(model: previewModel(status: "completed", isRoot: true, enforcement: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.light)
}

#Preview("No enforcement recorded - dark") {
    InspectorView(model: previewModel(status: "completed", isRoot: true, enforcement: false))
        .frame(width: 280, height: 560)
        .preferredColorScheme(.dark)
}

#Preview("Empty - light") {
    InspectorView(model: nil).frame(width: 280, height: 200).preferredColorScheme(.light)
}

#Preview("Empty - dark") {
    InspectorView(model: nil).frame(width: 280, height: 200).preferredColorScheme(.dark)
}
#endif
