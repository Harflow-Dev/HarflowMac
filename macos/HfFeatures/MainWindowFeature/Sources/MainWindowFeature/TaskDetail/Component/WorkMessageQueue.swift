import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkMessageQueue

/// Durable engine message state, shared by task and workflow composers.
enum WorkMessageQueue {
    struct Item: Identifiable, Equatable {
        let id: String
        let text: String
        let status: String
        let reason: String?
        var source: QueuedMessageState.Source = .standalone
        var canCancel: Bool { status == "queued" }
    }

    static func items(raw: [String: JSONValue], source: QueuedMessageState.Source? = nil) -> [Item] {
        QueuedMessageState.project(raw: raw, source: source ?? Self.source(raw)).map { value in
            Item(id: value.id, text: value.text ?? "", status: value.raw["status"]?.stringValue ?? "unknown", reason: value.reason, source: value.source)
        }
    }

    static func source(_ raw: [String: JSONValue]) -> QueuedMessageState.Source {
        guard raw["workflow_run_id"]?.stringValue != nil else { return .standalone }
        if let taskID = raw["task_id"]?.stringValue { return .workflowNode(taskID: taskID) }
        return .workflowRun
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
        case unknown(String)
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
        case .unknown: "Delivery status unavailable"
        }
    }

    var note: String? {
        switch kind {
        case .queued(_, let note): note
        case .undeliverable(let reason): reason
        case .uncertain(let reason):
            ["Delivery could not be confirmed. The message is not requeued.", reason].compactMap(\.self).joined(separator: "\n")
        case .unknown(let status): status
        }
    }

    /// The sentence under a queued bubble when Send now is refused. An unsafe interruption uses the
    /// approved wording; every other refusal keeps the engine's message.
    static func refusalNote(in result: [String: JSONValue]) -> String? {
        let refusal = result["refusal"]?.objectValue
        if refusal?["code"]?.stringValue == "interrupt_unsupported" {
            return "Send now isn't available. This operation can't be interrupted safely."
        }
        let explanation = refusal?["message"]?.stringValue
        let note = result["note"]?.stringValue
        let lines = [explanation, note].compactMap(\.self).reduce(into: [String]()) { result, line in
            if !line.isEmpty, !result.contains(line) { result.append(line) }
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
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
        let values = QueuedMessageState.project(raw: raw, source: WorkMessageQueue.source(raw))
        return project(states: values, notes: notes)
    }

    private static func project(states values: [QueuedMessageState], notes: [String: String]) -> [WorkMessageBubble] {
        applying(values.compactMap { value in
            let kind: Kind
            switch value.state {
            case .queued:
                let note = refusalNote(in: value.raw)
                kind = .queued(canCancel: true, note: note)
            case .delivering: kind = .queued(canCancel: false, note: refusalNote(in: value.raw))
            case .uncertain: kind = .uncertain(value.reason)
            case .undeliverable: kind = .undeliverable(value.reason)
            case .unknown(let status): kind = .unknown(status)
            case .delivered, .cancelled: return nil
            }
            return WorkMessageBubble(id: value.id, seq: value.sequence, kind: kind, text: value.text ?? "")
        }, notes: notes)
    }

    static func project(items: [WorkMessageQueue.Item], notes: [String: String] = [:]) -> [WorkMessageBubble] {
        let states = items.enumerated().flatMap { index, item in
            var value: [String: JSONValue] = ["id": .string(item.id), "seq": .number(Double(index)),
                "status": .string(item.status), "text": .string(item.text)]
            if let reason = item.reason { value["reason"] = .string(reason) }
            return QueuedMessageState.project(raw: ["messages": .array([.object(value)])], source: item.source)
        }
        return project(states: states, notes: notes)
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
                     "reason": .string("The workflow ended before this message could be delivered.")]),
            .object(["id": .string("d"), "seq": .number(4), "status": .string("delivering"), "text": .string("An uncertain delivery."),
                     "reason": .string("The engine could not confirm delivery.")]),
            .object(["id": .string("e"), "seq": .number(5), "status": .string("future-status"), "text": .string("A read-only unknown state.")])
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
