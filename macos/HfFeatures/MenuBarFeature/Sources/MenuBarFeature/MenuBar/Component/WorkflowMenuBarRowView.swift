import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowMenuBarRowView

/// One workflow run as a card (§6.8): `cardFill`, radius 12, and the shared hairline border —
/// except a needs-attention run, whose border is the palette's 35% warning tone. The status label
/// keeps the VM's exact copy, including its intentional Title Case ("Needs Attention"), which the
/// user's only-copy-change rule preserves over the general sentence-case guideline.
struct WorkflowMenuBarRowView: View {
    let model: WorkflowMenuBarRow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ActivityCard(border: model.needsAttention ? Color.warningBorder : nil) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                    HStack(spacing: HfRadius.Metrics.spacing8) {
                        leadingIcon
                        Text(model.name).font(.hf(.body, weight: .medium)).lineLimit(1)
                        Spacer(minLength: HfRadius.Metrics.spacing4)
                        trailing
                    }
                    Text(model.detail).font(.hf(.caption)).foregroundStyle(Color.secondaryText).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

// MARK: - WorkflowMenuBarRowView trailing meta

extension WorkflowMenuBarRowView {
    /// What the row shows at its trailing edge.
    enum Trailing: Equatable {
        case elapsed(since: Date)
        case status(String)
    }

    /// A running run with a known start shows its elapsed time; every other row, and a running one whose
    /// listing carried no start time, keeps its status label (a time is never invented).
    nonisolated static func trailing(for row: WorkflowMenuBarRow) -> Trailing {
        if row.isRunning, let startedAt = row.startedAt { return .elapsed(since: startedAt) }
        return .status(row.statusLabel)
    }

    @ViewBuilder private var trailing: some View {
        switch Self.trailing(for: model) {
        case .elapsed(let startedAt):
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Format.clock(max(0, context.date.timeIntervalSince(startedAt))))
                    .font(.hf(.caption))
                    .monospacedDigit()
                    .foregroundStyle(Color.tertiaryText)
            }
        case .status(let label):
            Text(label)
                .font(.hf(.caption, weight: model.needsAttention ? .semibold : .regular))
                .foregroundStyle(model.needsAttention ? Color.warningFG : Color.secondaryText)
        }
    }
}

// MARK: - WorkflowMenuBarRowView leading icon

extension WorkflowMenuBarRowView {
    /// Working: the spinner. Needs attention: the raised hand. A terminal status: its approved glyph (the workflow
    /// glyph when done). Anything else keeps the branch symbol.
    @ViewBuilder private var leadingIcon: some View {
        let status = TaskStatus(model.status)
        if model.isRunning {
            RunningSpinner()
.frame(width: HfRadius.Metrics.statusIconSize, height: HfRadius.Metrics.statusIconSize)
                .accessibilityLabel("Workflow run, running")
        } else if model.isWorking {
            RunningSpinner().frame(width: HfRadius.Metrics.statusIconSize, height: HfRadius.Metrics.statusIconSize)
        } else if model.needsAttention {
            StatusIcon(status: .other("needs_attention"), kind: .workflowRun)
        } else if status.isTerminal {
            StatusIcon(status: status, kind: .workflowRun)
        } else {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.secondaryText)
        }
    }
}

#if DEBUG
@MainActor
private func workflowMenuBarRowPreview(status: String, attentionReason: String? = nil) -> some View {
    var raw: [String: JSONValue] = [
        "workflow_run_id": .string("preview"), "name": .string("Implement and review"), "status": .string(status),
        "created_at": .number(Date.now.addingTimeInterval(-754).timeIntervalSince1970)
    ]
    if let attentionReason { raw["attention_reason"] = .string(attentionReason) }
    let model = WorkflowMenuBarRow(raw)
    return Group {
        if let model { WorkflowMenuBarRowView(model: model, onTap: {}).padding().frame(width: HfRadius.Metrics.menuBarPopoverWidth) }
    }
}

#Preview("Workflow row, attention - light") {
    workflowMenuBarRowPreview(status: "needs_attention", attentionReason: "Implementation reached its attempt limit.")
        .preferredColorScheme(.light)
}

#Preview("Workflow row, attention - dark") {
    workflowMenuBarRowPreview(status: "needs_attention", attentionReason: "Implementation reached its attempt limit.")
        .preferredColorScheme(.dark)
}

#Preview("Workflow row, working - light") {
    workflowMenuBarRowPreview(status: "running").preferredColorScheme(.light)
}

#Preview("Workflow row, working - dark") {
    workflowMenuBarRowPreview(status: "running").preferredColorScheme(.dark)
}

#Preview("Workflow row, settled - light") {
    workflowMenuBarRowPreview(status: "completed").preferredColorScheme(.light)
}

#Preview("Workflow row, settled - dark") {
    workflowMenuBarRowPreview(status: "completed").preferredColorScheme(.dark)
}
#endif
