import HfUI
import SwiftUI

// MARK: - NeedsYouDetailView

struct NeedsYouDetailView<VM: NeedsYouViewModel>: View {
    let viewModel: VM
    @State private var textExpanded = false

    private var presentation: NeedsYouPresentation { viewModel.presentation }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                Button { viewModel.didTapBack() } label: { Label("Needs you", systemImage: "chevron.left") }
                    .buttonStyle(.link)
                if let detail = presentation.detail {
                    header(detail)
                    if let note = detail.reviewNote {
                        Text(note).font(.hf(.secondary)).foregroundStyle(Color.warningFG).accessibilityAddTraits(.updatesFrequently)
                    }
                    card(detail)
                    provenance(detail)
                } else {
                    ProgressView("Loading request…").frame(maxWidth: .infinity, minHeight: 160)
                }
            }
            .padding(HfRadius.Metrics.spacing16)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ detail: NeedsYouDetail) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
            NeedsYouKindChip(label: detail.kindLabel)
            Text(detail.title).font(.hf(.title)).accessibilityAddTraits(.isHeader)
            if detail.pathTitles.count > 1 { NeedsYouPath(titles: detail.pathTitles) }
        }
    }

    @ViewBuilder private func card(_ detail: NeedsYouDetail) -> some View {
        switch detail.phase {
        case .settled(let decision, let answer, let note):
            settledCard(detail, decision: decision, answer: answer, note: note)
        case .expired:
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
                Text("\(detail.sourceLine) · Expired").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
                Text("This request is no longer pending").font(.hf(.headline))
                Text("It expired before it was answered, or another responder answered it. Nothing was sent.")
                    .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            .padding(HfRadius.Metrics.spacing12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
            .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
        case .answerable, .submitting, .withdrawn:
            pendingCard(detail)
        }
    }

    private func settledCard(_ detail: NeedsYouDetail, decision: String, answer: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
            Text(detail.sourceLine).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            Text("\(decision) by Harflow").font(.hf(.headline))
            if !answer.isEmpty { Text(answer).font(.hf(.body)).textSelection(.enabled) }
            Text(note).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        }
        .padding(HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.hairline))
        .accessibilityElement(children: .combine)
    }

    private func pendingCard(_ detail: NeedsYouDetail) -> some View {
        let withdrawn = detail.phase == .withdrawn
        let busy = detail.phase == .submitting || withdrawn
        return VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing10) {
            Text(detail.sourceLine).font(.hf(.secondary, weight: .semibold)).foregroundStyle(Color.warningFG)
            if detail.kind == .recovery {
                Text("Attempt limit reached").font(.hf(.headline))
            }
            requestBody(detail)
            if withdrawn {
                HStack {
                    Text("Harflow could not read this request right now.").font(.hf(.secondary)).foregroundStyle(Color.warningFG)
                    Button("Try again") { viewModel.didTapRetry() }.buttonStyle(.link)
                }
            }
            if let error = detail.error {
                Text(error).font(.hf(.secondary)).foregroundStyle(Color.failedRed).textSelection(.enabled)
            }
            controls(detail, busy: busy)
            if detail.phase == .submitting {
                Text("Submitting your \(detail.kind == .approval ? "decision" : "answer") to the engine…")
                    .font(.hf(.caption))
.foregroundStyle(Color.secondaryText)
.accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warningBG, in: RoundedRectangle(cornerRadius: HfRadius.row))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).stroke(Color.warningFG))
    }

    @ViewBuilder private func requestBody(_ detail: NeedsYouDetail) -> some View {
        if let approval = detail.approval {
            Text(approval.title).font(.hf(.body, weight: .semibold))
            ForEach(approval.fields) { field in
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                    Text("\(field.label) · \(field.type)").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                    Text(verbatim: field.value)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(HfRadius.Metrics.spacing6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.composerFill, in: RoundedRectangle(cornerRadius: 6))
                }
            }
        } else {
            Text(detail.text)
                .font(.hf(.reading))
                .lineLimit(detail.isLong && !textExpanded ? 10 : nil)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if detail.isLong {
                Button(textExpanded ? "Show less" : "Show more") { textExpanded.toggle() }.buttonStyle(.link).font(.hf(.caption))
            }
            if detail.kind == .recovery {
                Text("The run stopped after its configured attempts. The checkpoint stays as it is until an answer arrives.")
                    .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
            }
            if let hint = detail.resumeHint { Text(hint).font(.hf(.secondary)).foregroundStyle(Color.secondaryText) }
        }
    }

    @ViewBuilder private func controls(_ detail: NeedsYouDetail, busy: Bool) -> some View {
        Text(detail.ownershipNote).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        if detail.kind == .approval {
            HStack {
                Button(detail.phase == .submitting ? "Submitting…" : "Approve once") { viewModel.didDecide(approve: true) }
                    .buttonStyle(.borderedProminent)
                Button("Reject", role: .destructive) { viewModel.didDecide(approve: false) }
            }
            .disabled(busy)
        } else if let offered = detail.offeredAnswers {
            HStack {
                ForEach(offered, id: \.self) { answer in
                    Button(answer) { viewModel.didChooseOffered(answer) }.disabled(busy)
                }
            }
        } else {
            answerControls(detail, busy: busy)
        }
    }

    @ViewBuilder private func answerControls(_ detail: NeedsYouDetail, busy: Bool) -> some View {
        @Bindable var model = viewModel
        Text(detail.kind == .recovery ? "Answer" : "Your answer").font(.hf(.secondary, weight: .semibold))
        TextEditor(text: $model.answerText)
            .font(.hf(.body))
            .frame(minHeight: 88)
            .scrollContentBackground(.hidden)
            .padding(HfRadius.Metrics.spacing4)
            .background(Color.composerFill, in: RoundedRectangle(cornerRadius: HfRadius.row))
            .disabled(busy)
            .accessibilityLabel(detail.kind == .recovery ? "Answer" : "Your answer")
        if detail.kind == .recovery, detail.canAddAttempts {
            Stepper("Additional attempts: \(viewModel.additionalAttempts)", value: $model.additionalAttempts, in: 0 ... 99).disabled(busy)
        }
        Button(detail.phase == .submitting ? "Submitting…" : detail.kind == .recovery ? "Resume with answer" : "Send answer") { viewModel.didSubmitAnswer() }
            .buttonStyle(.borderedProminent)
            .disabled(busy || viewModel.answerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private func provenance(_ detail: NeedsYouDetail) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
            Text("Provenance and ownership").font(.hf(.secondary, weight: .semibold)).accessibilityAddTraits(.isHeader)
            ForEach(detail.provenance) { field in
                HStack(alignment: .top) {
                    Text(field.label).foregroundStyle(Color.secondaryText).frame(width: 110, alignment: .leading)
                    Text(field.value).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.hf(.secondary))
                .accessibilityElement(children: .combine)
            }
        }
    }
}
