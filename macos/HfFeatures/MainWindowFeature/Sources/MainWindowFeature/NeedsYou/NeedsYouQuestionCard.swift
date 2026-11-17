import HfUI
import SwiftUI

// MARK: - NeedsYouQuestionCard

/// Approved workflow question design: Design9093e75, states-workflow-questions.js, all four card states.
struct NeedsYouQuestionCard: View {
    let detail: NeedsYouDetail
    @Binding var draft: String
    let send: (String?) -> Void
    let retry: () -> Void
    let openRun: () -> Void
    @FocusState private var answerFocused: Bool

    private var busy: Bool { detail.phase != .answerable }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { heading; Spacer(minLength: 8); source }
                VStack(alignment: .leading, spacing: 4) { heading; source }
            }
            .padding(.horizontal, 14)
.padding(.vertical, 10)
            .background(Color.warningBG)
            VStack(alignment: .leading, spacing: 12) {
                Text(detail.text).font(.hf(.body)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                ForEach(detail.questionItems, id: \.self) { Text($0).font(.hf(.body)).textSelection(.enabled) }
                state
            }
            .padding(.horizontal, 14)
.padding(.vertical, 12)
            Button("Open run", action: openRun)
.buttonStyle(.plain)
                .font(.hf(.secondary))
.padding(.horizontal, 14)
.padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
        .clipShape(RoundedRectangle(cornerRadius: HfRadius.row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow question")
    }

    private var heading: some View {
        Label("Asks a question", systemImage: "hand.raised").font(.hf(.secondary, weight: .semibold)).foregroundStyle(Color.warningFG)
    }

    private var source: some View {
        Text("Workflow: \(detail.title)\(detail.pathTitles.last.map { " · step \($0)" } ?? "")")
            .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
.fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var state: some View {
        switch detail.phase {
        case .settled(let decision, let answer, let note):
            VStack(alignment: .leading, spacing: 8) {
                Text(decision).font(.hf(.headline)).accessibilityAddTraits(.isHeader)
                Text(note).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                if !answer.isEmpty { Text(answer).font(.hf(.body)).textSelection(.enabled) }
                savedDraft
            }
        case .expired:
            Text("This request is no longer pending").font(.hf(.headline))
            Text("This request is no longer available here. Nothing was sent.").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            savedDraft
        case .readOnly(let lines, _):
            ForEach(lines, id: \.self) { Text($0).font(.hf(.secondary)).textSelection(.enabled) }
            savedDraft
        case .answerable, .submitting, .withdrawn:
            Text(detail.ownershipNote).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            if detail.phase == .withdrawn {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Harflow could not read this request right now.").font(.hf(.secondary)).foregroundStyle(Color.warningFG)
                    Button("Try again", action: retry).buttonStyle(.link)
                }
            }
            if let error = detail.error { Text(error).font(.hf(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
            if let offered = detail.offeredAnswers {
                Text("Choose one of the offered answers.").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                ViewThatFits(in: .horizontal) {
                    HStack { offeredButtons(offered) }
                    VStack(alignment: .leading) { offeredButtons(offered) }
                }
            } else {
                Text("Your answer").font(.hf(.secondary, weight: .semibold))
                TextEditor(text: $draft)
.font(.hf(.body))
.frame(height: 88)
                    .scrollContentBackground(.hidden)
.padding(4)
                    .background(Color.windowBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
                    .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
                    .disabled(busy)
.focused($answerFocused)
.accessibilityLabel("Your answer")
                Button(detail.phase == .submitting ? "Submitting…" : "Send answer") { send(nil) }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .background {
                        if answerFocused {
                            Button("") { send(nil) }
.keyboardShortcut(.return, modifiers: .command)
                                .hidden()
.accessibilityHidden(true)
                                .disabled(busy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
            }
            if detail.phase == .submitting { Text("Submitting your answer to the engine…").font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
        }
    }

    private func offeredButtons(_ answers: [String]) -> some View {
        ForEach(answers, id: \.self) { answer in Button(answer) { send(answer) }.disabled(busy) }
    }

    @ViewBuilder private var savedDraft: some View {
        if let saved = detail.savedDraft {
            Text("Your saved draft").font(.hf(.secondary, weight: .semibold))
            Text(saved).font(.hf(.body)).textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview {
    NeedsYouQuestionCard(detail: NeedsYouPresentationMapper.detail(NeedsYouPreviewFixtures.question()), draft: .constant(""),
                         send: { _ in }, retry: {}, openRun: {}).padding()
}
#endif
