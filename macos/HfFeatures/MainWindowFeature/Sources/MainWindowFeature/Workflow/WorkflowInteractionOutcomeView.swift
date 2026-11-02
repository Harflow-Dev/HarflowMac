import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowInteractionOutcomeView

/// A durable engine receipt and the unsent draft retained after a competing answer wins.
struct WorkflowInteractionOutcomeView: View {
    let receipt: WorkflowInteractionReceipt
    var savedDraft: String?
    var isRaceOutcome = false

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
            Text(receipt.answeredBy == .caller
                 ? (isRaceOutcome ? "Already answered by the caller" : "Answered by the caller")
                 : "Answered in Harflow")
                .font(.hf(.secondary, weight: .semibold))
            Text(Date(timeIntervalSince1970: receipt.answeredAt).formatted(date: .abbreviated, time: .shortened))
                .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
            if receipt.answerTruncated {
                Text("Answer excerpt").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            }
            Text(receipt.answer).font(.hf(.body)).textSelection(.enabled)
            if let savedDraft, !savedDraft.isEmpty {
                Text("Your saved draft").font(.hf(.secondary, weight: .semibold))
                Text(savedDraft).font(.hf(.body)).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(HfRadius.Metrics.spacing12)
        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
    }
}

#if DEBUG
#Preview("Caller answered first") {
    if let receipt = WorkflowInteractionReceipt(.object([
        "interaction_id": .string("question-1"), "workflow_run_id": .string("root"),
        "action": .string("resume"), "answer": .string("Use staging"),
        "answered_by": .string("caller"), "answered_at": .number(1793059200)
    ])) {
        WorkflowInteractionOutcomeView(receipt: receipt, savedDraft: "Check production first", isRaceOutcome: true)
            .frame(width: 420)
.padding()
    }
}
#endif
