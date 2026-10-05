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
        HStack(spacing: 4) {
        if !isEditable {
            let statusLabel = status == "not_selected" ? "Not selected" : status.replacingOccurrences(of: "_", with: " ").capitalized
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
                Spacer(minLength: 0)
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
#Preview("Optional node detail") {
    WorkflowNodeDetail(node: WorkflowNodeModel(raw: ["type": .string("agent"), "optional": .bool(true)]), status: "pending", isEditable: true)
}
#endif
