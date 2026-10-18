import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowOnDemandCallsView

struct WorkflowOnDemandCallsView: View {
    let node: WorkflowNodeModel
    let calls: [WorkflowOnDemandCall]
    let onOpenTask: (String) -> Void

    var body: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            HStack {
                Text(header)
                    .font(.pb(.secondary, weight: .semibold))
                Spacer()
                Text("\(calls.count) calls · one at a time").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            }.padding(PbRadius.Metrics.spacing12)
            Divider()
            if calls.isEmpty {
                ContentUnavailableView("Not called", systemImage: "bolt", description: Text("This node runs only when the orchestrator calls it."))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
                        ForEach(Array(calls.reversed())) { call in
                            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                                HStack {
                                    Text("#\(call.number) · \(call.assignment)").font(.pb(.body, weight: .semibold))
                                    Spacer()
                                    WorkflowOnDemandCallBadge(call: call)
                                }
                                Text(call.origin).font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                                if !call.reason.isEmpty { Text(call.reason).font(.pb(.body)) }
                                if !call.result.isEmpty { ReadingMarkdownView(text: call.result) }
                                if let id = call.taskID { Button("Open task") { onOpenTask(id) }.buttonStyle(QuietButtonStyle()) }
                            }
                            .textSelection(.enabled)
                            .padding(PbRadius.Metrics.spacing12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.inspectorFill, in: RoundedRectangle(cornerRadius: PbRadius.card))
                        }
                    }
.padding(PbRadius.Metrics.spacing12)
.background(ScrollChrome())
                }
            }
        }.accessibilityIdentifier("workflow-on-demand-calls")
    }

    private var header: String {
        let access = WorkflowAccess.title(node.raw["freedom"]?.stringValue ?? "read_only")
        return "\(node.name) · \(node.backend) · on demand · \(access) · network \(network)"
    }

    private var network: String { node.raw["effective_network"]?.boolValue.map { $0 ? "on" : "off" } ?? "unspecified" }
}

// MARK: - WorkflowOnDemandCallBadge

struct WorkflowOnDemandCallBadge: View {
    let call: WorkflowOnDemandCall

    var body: some View {
        if call.status == "running", call.raw["started_at"]?.doubleValue != nil {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in badge(now: timeline.date) }
        } else {
            badge(now: .now)
        }
    }

    private func badge(now: Date) -> some View {
        StatusBadge(status: taskStatus, elapsedText: elapsed(now: now))
    }

    private var taskStatus: TaskStatus {
        switch call.status {
        case "succeeded": .completed
        case "running": .running
        case "failed": .failed
        case "cancelled": .cancelled
        default: .other(call.status)
        }
    }

    private func elapsed(now: Date) -> String? {
        guard let start = call.raw["started_at"]?.doubleValue else { return nil }
        let finish = call.raw["finished_at"]?.doubleValue
        guard finish != nil || call.status == "running" else { return nil }
        let seconds = Int(max(0, (finish ?? now.timeIntervalSince1970) - start))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

#if DEBUG
#Preview("On-demand calls light") {
    WorkflowOnDemandCallsView(node: WorkflowNodeModel(raw: ["title": .string("Researcher")]), calls: [], onOpenTask: { _ in }).preferredColorScheme(.light)
}

#Preview("On-demand calls dark") {
    WorkflowOnDemandCallsView(node: WorkflowNodeModel(raw: ["title": .string("Researcher")]), calls: [], onOpenTask: { _ in }).preferredColorScheme(.dark)
}
#endif
