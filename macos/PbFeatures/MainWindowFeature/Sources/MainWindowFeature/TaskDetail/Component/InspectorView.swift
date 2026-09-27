//
//  InspectorView.swift
//  MainWindowFeature
//
//  Ported from the app target's `InspectorView.swift`. "Now" reads the timeline's current running
//  tool; "Details"/"Enforcement" read the raw snapshot (falling back to the listing). "Files
//  changed" (git) and the "Branch" row are gone (piece 2/3 of the Monitor architecture plan — see
//  the Summary tab's "Files the agent edited" section instead); "Activity" and "Details" are now
//  collapsible, expanded by default.
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
    let onSelectTask: (String) -> Void

    /// "Enforcement was not recorded for this task." only once a snapshot exists but carried no
    /// enforcement data — never while the snapshot itself hasn't loaded.
    static func showsEnforcementNotRecorded(detail: TaskInfo, hasSnapshot: Bool) -> Bool {
        detail.enforcement == nil && hasSnapshot
    }
}

// MARK: - InspectorView

struct InspectorView: View {
    let model: InspectorModel?
    @State private var activityExpanded = true
    @State private var detailsExpanded = true

    var body: some View {
        ScrollView {
            if let model {
                VStack(alignment: .leading, spacing: 16) {
                    if model.task.status.isRunning {
                        section("Now") {
                            if let current = model.current, case .tool(let call, _) = current.body {
                                Text(call.tool).font(.pb(.body, weight: .medium))
                                Text(call.headline).font(.pb(.secondary, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                                if let startedAt = current.at {
                                    TimelineView(.periodic(from: .now, by: 1)) { context in
                                        Text("\(Format.clock(context.date.timeIntervalSince(startedAt))) · step \(model.stepCount)")
                                            .font(.pb(.caption))
                                            .monospacedDigit()
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } else {
                                Text("Thinking or writing").font(.pb(.body)).foregroundStyle(.secondary)
                            }
                        }
                    }
                    collapsibleSection("Activity", isExpanded: $activityExpanded) {
                        Text("\(model.activity.toolCalls) tool calls · \(model.activity.edits) edits · "
                             + "\(model.activity.commands) commands · \(model.subtaskCount) sub-tasks")
                        .font(.pb(.secondary))
                    }
                    if !model.task.isRoot { lineage(model) }
                    collapsibleSection("Details", isExpanded: $detailsExpanded) { details(model) }
                    if !model.notices.isEmpty {
                        section("Notices") {
                            ForEach(Array(model.notices.enumerated()), id: \.offset) { _, notice in
                                Text(notice).font(.pb(.secondary)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(14)
            }
        }
        .background(Color.inspectorFill)
    }
    
    @ViewBuilder
    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            content()
        }
    }

    @ViewBuilder
    private func collapsibleSection(_ title: String, isExpanded: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        DisclosureGroup(isExpanded: isExpanded) {
            // macOS centres a DisclosureGroup's content unless it is given the full width.
            content().padding(.top, 6).frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            SectionLabel(text: title)
        }
    }
    
    private func lineage(_ model: InspectorModel) -> some View {
        VStack(alignment: .leading, spacing: 16) {
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
                BackendBadge(backend: entry.task.backend, size: 16)
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
        ForEach(EnforcementText.lines(detail.enforcement), id: \.self) { line in
            Text(line).font(.pb(.secondary)).foregroundStyle(.secondary)
        }
        if InspectorModel.showsEnforcementNotRecorded(detail: detail, hasSnapshot: model.hasSnapshot) {
            Text("Enforcement was not recorded for this task.").font(.pb(.secondary)).foregroundStyle(.secondary)
        }
    }
    
    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.pb(.secondary)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.pb(.secondary)).textSelection(.enabled).lineLimit(3)
        }
    }
}

#if DEBUG
#Preview {
    InspectorView(model: nil)
        .frame(width: 280, height: 500)
}
#endif
