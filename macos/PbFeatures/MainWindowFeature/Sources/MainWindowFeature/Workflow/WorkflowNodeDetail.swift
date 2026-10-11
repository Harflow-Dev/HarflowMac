import PbUI
import SwiftUI

// MARK: - WorkflowNodeDetail

struct WorkflowNodeDetail: View {
    let node: WorkflowNodeModel
    let status: String
    let isEditable: Bool
    var childRunID: String?
    var onOpenRun: (String) -> Void = { _ in }

    var body: some View {
        HStack(spacing: PbRadius.Metrics.spacing4) {
        if !isEditable {
            let statusLabel = WorkflowNodeStatusPresentation.presentation(status: status).label
            let fullStatus = statusLabel + (node.isOptional ? " · Optional" : "")
            Text(fullStatus)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .help(fullStatus)
                .accessibilityLabel(fullStatus)
                .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
        } else if node.isOptional {
            Text("Optional").lineLimit(1).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
            if node.type == "workflow", let childRunID {
                Spacer(minLength: PbRadius.Metrics.zero)
                Button("Open workflow") { onOpenRun(childRunID) }
                    .font(.pb(.caption))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Open workflow \(node.workflowName)")
            }
        }
    }
}

#if DEBUG
#Preview("Optional node detail - light") {
    WorkflowNodeDetail(node: WorkflowNodeModel(raw: ["type": .string("agent"), "optional": .bool(true)]), status: "pending", isEditable: true)
        .preferredColorScheme(.light)
}

#Preview("Node detail - dark, failed") {
    WorkflowNodeDetail(node: WorkflowNodeModel(raw: ["type": .string("agent"), "optional": .bool(true)]), status: "failed", isEditable: false)
        .preferredColorScheme(.dark)
}

#Preview("Node detail - unknown, light") {
    WorkflowNodeDetail(node: WorkflowNodeModel(raw: ["type": .string("agent")]), status: "waiting_for_owner", isEditable: false)
        .preferredColorScheme(.light)
}
#endif
