import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkMessageQueue

/// Durable engine message state, shared by task and workflow composers.
struct WorkMessageQueue: View {
    struct Item: Identifiable, Equatable {
        let id: String
        let text: String
        let status: String
        let reason: String?
        var canCancel: Bool { status == "queued" }
    }

    let items: [Item]
    let isBusy: Bool
    let onCancel: (String) -> Void

    static func items(raw: [String: JSONValue]) -> [Item] {
        let values = raw["messages"]?.arrayValue ?? raw["queued_followups"]?["items"]?.arrayValue ?? []
        return values.compactMap { value in
            guard let id = value["id"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
            return Item(id: id, text: value["text"]?.stringValue ?? "", status: status,
                        reason: value["reason"]?.stringValue)
        }
    }

    var body: some View {
        if !items.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    ForEach(items) { item in
                        HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                                Text(item.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.hf(.caption, weight: .semibold))
                                if !item.text.isEmpty { Text(item.text).textSelection(.enabled) }
                                if let reason = item.reason { Text(reason).foregroundStyle(Color.secondaryText) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if item.canCancel {
                                Button("Cancel") { onCancel(item.id) }
                                    .buttonStyle(.plain)
                                    .disabled(isBusy)
                                    .accessibilityLabel("Cancel queued message")
                            }
                        }
                    }
                }
                .font(.hf(.secondary))
                .padding(.horizontal, HfRadius.Metrics.spacing24)
                .padding(.vertical, HfRadius.Metrics.spacing8)
            }
            .frame(maxHeight: 120)
        }
    }
}

#if DEBUG
#Preview("Queued work messages") {
    WorkMessageQueue(items: [.init(id: "example", text: "Check the evidence before continuing.", status: "queued", reason: nil)],
                     isBusy: false, onCancel: { _ in })
        .frame(width: 600)
}
#endif
