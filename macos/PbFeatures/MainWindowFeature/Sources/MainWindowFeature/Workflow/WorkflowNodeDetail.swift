import PbUI
import SwiftUI

// MARK: - WorkflowNodeDetail

struct WorkflowNodeDetail: View {
    let node: WorkflowNodeModel
    let status: String
    let isEditable: Bool

    var body: some View {
        if !isEditable {
            Text(status.replacingOccurrences(of: "_", with: " ").capitalized + (node.isOptional ? " · Optional" : ""))
                .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
        } else if node.isOptional {
            Text("Optional").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
        }
    }
}

#if DEBUG
#Preview("Optional node detail") {
    WorkflowNodeDetail(node: WorkflowNodeModel(raw: ["type": .string("agent"), "optional": .bool(true)]), status: "pending", isEditable: true)
}
#endif
