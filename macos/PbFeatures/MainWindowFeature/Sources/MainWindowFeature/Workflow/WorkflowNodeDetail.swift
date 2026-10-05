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
        VStack(alignment: .leading, spacing: 4) {
        if !isEditable {
            let statusLabel = status == "not_selected" ? "Not selected" : status.replacingOccurrences(of: "_", with: " ").capitalized
            Text(statusLabel + (node.isOptional ? " · Optional" : ""))
                .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
        } else if node.isOptional {
            Text("Optional").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
            if node.type == "workflow", let childRunID {
                Button("Open workflow") { onOpenRun(childRunID) }
                    .font(.pb(.caption))
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
