import MonitorCore
import PbUI
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
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
                    HStack(spacing: PbRadius.Metrics.spacing8) {
                        if model.isWorking {
                            RunningSpinner().frame(width: PbRadius.Metrics.statusIconSize, height: PbRadius.Metrics.statusIconSize)
                        } else {
                            Image(systemName: model.needsAttention ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                                .foregroundStyle(model.needsAttention ? Color.warningFG : Color.secondaryText)
                        }
                        Text(model.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                        Spacer(minLength: PbRadius.Metrics.spacing4)
                        Text(model.statusLabel)
                            .font(.pb(.caption, weight: model.needsAttention ? .semibold : .regular))
                            .foregroundStyle(model.needsAttention ? Color.warningFG : Color.secondaryText)
                    }
                    Text(model.detail).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

#if DEBUG
@MainActor
private func workflowMenuBarRowPreview(status: String, attentionReason: String? = nil) -> some View {
    var raw: [String: JSONValue] = [
        "workflow_run_id": .string("preview"), "name": .string("Implement and review"), "status": .string(status)
    ]
    if let attentionReason { raw["attention_reason"] = .string(attentionReason) }
    let model = WorkflowMenuBarRow(raw)
    return Group {
        if let model { WorkflowMenuBarRowView(model: model, onTap: {}).padding().frame(width: PbRadius.Metrics.menuBarPopoverWidth) }
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
