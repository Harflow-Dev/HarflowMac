import PbUI
import SwiftUI

// MARK: - WorkflowMenuBarRowView

struct WorkflowMenuBarRowView: View {
    let model: WorkflowMenuBarRow
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ActivityCard {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        if model.isWorking {
                            RunningSpinner().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: model.needsAttention ? "exclamationmark.circle" : "arrow.triangle.branch")
                                .foregroundStyle(model.needsAttention ? Color.warningFG : Color.secondaryText)
                        }
                        Text(model.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(model.statusLabel).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                    }
                    Text(model.detail).font(.pb(.caption)).foregroundStyle(Color.secondaryText).lineLimit(2)
                }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}

#if DEBUG
#Preview {
    if let model = WorkflowMenuBarRow(["workflow_run_id": .string("preview"), "name": .string("Implement and review"),
                                      "status": .string("needs_attention"), "attention_reason": .string("Implementation reached its attempt limit.")]) {
        WorkflowMenuBarRowView(model: model, onTap: {}).padding().frame(width: 380)
    }
}
#endif
