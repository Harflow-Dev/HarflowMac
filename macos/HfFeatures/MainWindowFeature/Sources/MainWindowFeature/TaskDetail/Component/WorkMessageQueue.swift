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
    let onCancel: ((String) -> Void)?

    static func items(raw: [String: JSONValue]) -> [Item] {
        let values = raw["messages"]?.arrayValue ?? raw["queued_followups"]?["items"]?.arrayValue ?? []
        return values.compactMap { value in
            guard let id = value["id"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
            return Item(id: id, text: value["text"]?.stringValue ?? "", status: status,
                        reason: value["reason"]?.stringValue)
        }
    }

    var body: some View {
        WorkMessageBubblesView(bubbles: WorkMessageBubble.project(items: items), onCancel: onCancel, isCancelDisabled: isBusy)
    }
}

// MARK: - WorkMessageBubble

/// One queued-message bubble in a transcript. Pinned bubbles stay below live activity. Settled
/// ones stay above it. Approved in HarflowDesign `docs/queued-messages.md` on 2026-10-29.
struct WorkMessageBubble: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case queued(canCancel: Bool, note: String?)
        case undeliverable(String?)
        case uncertain(String?)
    }

    let id: String
    let seq: Int
    var kind: Kind
    let text: String

    var isPinned: Bool { if case .queued = kind { return true }; return false }
    var isPending: Bool { isPinned }
    var canCancel: Bool { if case .queued(let canCancel, _) = kind { return canCancel }; return false }

    var caption: String? {
        switch kind {
        case .queued: "Queued"
        case .undeliverable: "Undeliverable"
        case .uncertain: "Delivery uncertain"
        }
    }

    var note: String? {
        switch kind {
        case .queued(_, let note): note
        case .undeliverable(let reason), .uncertain(let reason): reason
        }
    }

    /// The sentence under a queued bubble when Send now is refused. An unsafe interruption uses the
    /// approved wording; every other refusal keeps the engine's message.
    static func refusalNote(in result: [String: JSONValue]) -> String? {
        let refusal = result["refusal"]?.objectValue
        if refusal?["code"]?.stringValue == "interrupt_unsupported" {
            return "Send now isn't available. This operation can't be interrupted safely."
        }
        return refusal?["message"]?.stringValue
    }

    static func applying(_ bubbles: [WorkMessageBubble], notes: [String: String]) -> [WorkMessageBubble] {
        bubbles.map { bubble in
            guard let note = notes[bubble.id], case .queued(let canCancel, nil) = bubble.kind else { return bubble }
            var copy = bubble
            copy.kind = .queued(canCancel: canCancel, note: note)
            return copy
        }
    }

    /// `messages` wins when that key is present. Otherwise an available `queued_followups` ledger
    /// is the same queue. Cancelled records are omitted, and so are delivered and consumed ones: once
    /// delivered, the transcript owns the message. Order is send order.
    static func project(raw: [String: JSONValue], notes: [String: String] = [:]) -> [WorkMessageBubble] {
        if let messages = raw["messages"]?.arrayValue {
            return applying(project(messages), notes: notes)
        }
        guard let ledger = raw["queued_followups"]?.objectValue, ledger["state"]?.stringValue == "available" else { return [] }
        return applying(project(ledger["items"]?.arrayValue ?? []), notes: notes)
    }

    static func project(items: [WorkMessageQueue.Item], notes: [String: String] = [:]) -> [WorkMessageBubble] {
        applying(items.enumerated().compactMap { index, item in
            guard let kind = kind(status: item.status, reason: item.reason, refusal: nil) else { return nil }
            return WorkMessageBubble(id: item.id, seq: index, kind: kind, text: item.text)
        }, notes: notes)
    }

    private static func project(_ values: [JSONValue]) -> [WorkMessageBubble] {
        values.compactMap { value in
            guard let id = value["id"]?.stringValue, let status = value["status"]?.stringValue else { return nil }
            let text = value["text"]?.stringValue ?? ""
            let reason = value["reason"]?.stringValue
            let refusal = value["refusal"]?.objectValue.flatMap { refusalNote(in: ["refusal": .object($0)]) }
            guard let kind = kind(status: status, reason: reason, refusal: refusal) else { return nil }
            return WorkMessageBubble(id: id, seq: value["seq"]?.intValue ?? Int.max, kind: kind, text: text)
        }
        .sorted { $0.seq == $1.seq ? $0.id < $1.id : $0.seq < $1.seq }
    }

    private static func kind(status: String, reason: String?, refusal: String?) -> Kind? {
        switch status {
        case "queued": .queued(canCancel: true, note: refusal)
        case "delivering", "reserved": .queued(canCancel: false, note: refusal)
        case "undeliverable": .undeliverable(reason)
        case "delivery_unknown": .uncertain(reason)
        default: nil // cancelled, delivered and consumed: the transcript owns delivered messages
        }
    }
}

// MARK: - WorkMessageBubblesView

/// Right-aligned user bubbles for one surface's queue. Removal fades unless Reduce Motion is on.
struct WorkMessageBubblesView: View {
    let bubbles: [WorkMessageBubble]
    var onCancel: ((String) -> Void)?
    var isCancelDisabled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: HfRadius.Metrics.spacing12) {
            ForEach(bubbles) { bubble in
                PromptBubbleView(text: bubble.text, caption: bubble.caption, isPending: bubble.isPending,
                                 disclosureID: bubble.id, note: bubble.note,
                                 onCancel: bubble.canCancel ? onCancel.map { cancel in { cancel(bubble.id) } } : nil,
                                 isCancelDisabled: isCancelDisabled)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : HfMotion.arrival, value: bubbles.map(\.id))
    }
}

// MARK: - QueuedMessageJump

/// The button that returns to pinned bubbles when the reader has left the live end.
struct QueuedMessageJump: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(count == 1 ? "Queued message" : "Queued messages", action: action)
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(HfRadius.Metrics.spacing8)
    }
}

#if DEBUG
private struct QueuedBubblePreview: View {
    var body: some View {
        let bubbles = WorkMessageBubble.project(raw: ["messages": .array([
            .object(["id": .string("a"), "seq": .number(1), "status": .string("queued"), "text": .string("Check the evidence before continuing."),
                     "refusal": .object(["code": .string("interrupt_unsupported"), "message": .string("busy")])]),
            .object(["id": .string("b"), "seq": .number(2), "status": .string("delivering"), "text": .string("Still on its way.")]),
            .object(["id": .string("c"), "seq": .number(3), "status": .string("undeliverable"), "text": .string("The earlier note."),
                     "reason": .string("The workflow ended before this message could be delivered.")])
        ])])
        WorkMessageBubblesView(bubbles: bubbles, onCancel: { _ in })
            .padding(HfRadius.Metrics.spacing16)
            .frame(width: 420)
            .background(Color.windowBG)
    }
}

#Preview("Queued bubbles - light") { QueuedBubblePreview().preferredColorScheme(.light) }
#Preview("Queued bubbles - dark") { QueuedBubblePreview().preferredColorScheme(.dark) }
#endif
