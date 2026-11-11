import Foundation
import HfUI
import SwiftUI

// MARK: - PendingLaunchDetailBody

/// Back, the state card, the facts, the action and the note, in that order.
struct PendingLaunchDetailBody: View {
    let detail: PendingLaunchDetailPresentation
    let reduceMotion: Bool
    let stopFocusRequest: Int
    let titleFocusRequest: Int
    let actions: PendingLaunchesActions

    @AccessibilityFocusState private var titleFocused: Bool
    @FocusState private var stopFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Button("Back to pending launches", systemImage: "chevron.left", action: actions.back)
                .accessibilityIdentifier("pending-launch-back")
            if detail.kind == .checking {
                checkingCard
            } else {
                card
            }
            facts
            actionsAndNotes
            Text(PendingLaunchDetailPresentation.note)
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { titleFocused = true }
        .onChange(of: stopFocusRequest) { _, _ in
            // Only a Stop that is shown and enabled can take focus; otherwise nothing is forced.
            if detail.stop == .enabled { DispatchQueue.main.async { stopFocused = true } }
        }
        .onChange(of: titleFocusRequest) { _, _ in
            titleFocused = false
            DispatchQueue.main.async { titleFocused = true }
        }
        // The card is replaced when the state leaves the placeholder; re-assert focus on the new title. Other
        // state changes keep focus where it is (for example on a pressed action).
        .onChange(of: detail.kind) { old, _ in
            guard old == .checking else { return }
            titleFocused = false
            DispatchQueue.main.async { titleFocused = true }
        }
    }

    /// Stop (left) and the read action in one row, then the notes in drawn order.
    private var actionsAndNotes: some View {
        VStack(alignment: .leading, spacing: 8) {
            if detail.stop != nil || detail.action != nil {
                HStack(spacing: 8) {
                    if let stop = detail.stop {
                        Button("Stop…", role: .destructive, action: actions.stop)
                            .buttonStyle(.bordered)
                            .disabled(stop == .disabled)
                            .focused($stopFocused)
                            .accessibilityIdentifier("pending-launch-stop")
                    }
                    if let action = detail.action {
                        Button(action == .checkTaskStatus ? "Check task status" : "Check again", action: handler(for: action))
                            .buttonStyle(.bordered)
                            .disabled(!detail.isActionEnabled)
                            .accessibilityIdentifier("pending-launch-detail-action")
                    }
                }
            }
            ForEach(Array(detail.notes.enumerated()), id: \.offset) { _, note in
                Text(note)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func handler(for action: PendingLaunchDetailPresentation.Action) -> () -> Void {
        action == .checkTaskStatus ? actions.checkTaskStatus : actions.detailCheckAgain
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(detail.title)
                .font(.hf(.title, weight: .semibold))
                .foregroundStyle(Color.primaryText)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($titleFocused)
            Text(detail.message)
                .font(.hf(.body))
                .lineSpacing(4)
                .foregroundStyle(Color.primaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
    }

    /// No copy is drawn before the first stored lookup: two shimmer lines in the standard card.
    private var checkingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            PendingLaunchSkeletonBar(width: 220, height: 16, reduceMotion: reduceMotion)
            PendingLaunchSkeletonBar(width: 320, height: 12, reduceMotion: reduceMotion)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: HfRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.card).stroke(Color.cardBorder, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail.title)
        .accessibilityFocused($titleFocused)
    }

    private var facts: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(detail.facts) { fact in
                GridRow {
                    Text(fact.label)
                        .font(.hf(.body))
                        .foregroundStyle(Color.secondaryText)
                        .frame(width: 100, alignment: .leading)
                    Text(fact.value)
                        .font(fact.isCode ? .hf(.body, design: .monospaced) : .hf(.body))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}
