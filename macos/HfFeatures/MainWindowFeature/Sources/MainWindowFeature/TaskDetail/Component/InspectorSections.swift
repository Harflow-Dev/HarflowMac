//
//  InspectorSections.swift
//  MainWindowFeature
//
//  The snapshot facts rows shared by the legacy `TaskSnapshotFactsView` and the standalone pane's Events groups:
//  supervision evidence, task details, lineage and limits. Moved out of `InspectorView.swift` unchanged.
//

import HfUI
import MonitorCore
import SwiftUI

// MARK: - InspectorSections

/// Reusable rows over an `InspectorModel`.
@MainActor
enum InspectorSections {

    /// A labelled block.
    @ViewBuilder
    static func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: title)
            content()
        }
    }

    @ViewBuilder
    static func supervision(_ model: InspectorModel) -> some View {
        if let evidence = model.detail.supervision {
            detailRow("Owner", evidence.ownerState ?? "Unavailable")
            detailRow("Process", evidence.processState ?? "Unavailable")
            detailRow("Capture", evidence.captureState ?? "Unavailable")
            detailRow("Live input", evidence.liveInputState ?? "Unavailable")
            if let cutoff = evidence.lastCapturedOutputAt {
                detailRow("Last raw-log write (approximate capture cutoff)", cutoff)
                detailRow("Capture source", evidence.lastCapturedOutputSource ?? "Unavailable")
            }
        } else {
            Text("Supervision evidence is unavailable.").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        }
        ForEach(Array(model.restartHistory.enumerated()), id: \.offset) { _, observation in
            VStack(alignment: .leading, spacing: 8) {
                Text("Server restart observed").font(.hf(.secondary))
                detailRow("Previous server", identity(observation.previousServer))
                detailRow(observation.observerKind == "parent_process" ? "Current observing process" : "Current server", identity(observation.observingProcess))
                if let started = observation.observedProcessStartedAt.flatMap(ISODate.parse) {
                    detailRow(
                        observation.observerKind == "parent_process" ? "Observing process started at" : "Observing server started at",
                        started.formatted(date: .abbreviated, time: .shortened)
                    )
                }
            }
        }
    }

    static func identity(_ value: TaskSupervision.ProcessIdentity) -> String {
        "PID \(value.pid) · \(value.startTime)"
    }

    static func lineage(_ model: InspectorModel) -> some View {
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
                        "Parent is \(parent.task.freedom ?? "unknown"). harflow refuses a sub-task that is less strict than its caller."
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
    
    static func lineageRow(_ entry: SubTaskEntry, indent: Int, currentTaskID: String, onSelectTask: @escaping (String) -> Void) -> some View {
        let current = entry.task.taskID == currentTaskID
        return Button {
            onSelectTask(entry.task.taskID)
        } label: {
            HStack(spacing: 6) {
                BackendLabel(backend: entry.task.backend).font(.hf(.caption))
                Text(entry.title).font(.hf(.secondary, weight: current ? .semibold : .regular)).lineLimit(1)
                Spacer()
                Text("depth \(entry.task.depth)").font(.hf(.caption)).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(indent) * 10)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }
    
    static func limit(_ name: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack { Text(name).font(.hf(.secondary, weight: .medium)); Spacer(); Text(value).font(.hf(.secondary)) }
            Text(note).font(.hf(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    
    @ViewBuilder
    static func details(_ model: InspectorModel) -> some View {
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
    
    static func detailName(_ name: String) -> some View {
        Text(name).font(.hf(.secondary)).foregroundStyle(Color.secondaryText).frame(width: 84, alignment: .leading)
    }

    static func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            detailName(name)
            Spacer(minLength: 8)
            Text(value).font(.hf(.secondary)).multilineTextAlignment(.trailing).textSelection(.enabled).lineLimit(3)
        }
    }
}
