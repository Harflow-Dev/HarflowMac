import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowGoalView

/// The run goal block: label, goal text, assessment row, revision history and the revise link, or its form and
/// answered-elsewhere states. The draft lives in the view model so every block of the run shares it.
struct WorkflowGoalView<VM: WorkflowViewModel>: View {
    var viewModel: VM
    let run: WorkflowRunModel
    var naturalHeight = false

    private var isEditing: Bool { viewModel.goalDraft?.runID == run.id }

    var body: some View {
        // Drawn only from the projection of this run; until it arrives nothing is built on the main actor.
        if let model = viewModel.goalPresentation(for: run) {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                if let outcome = viewModel.goalAnsweredElsewhere(for: model) {
                    answeredCard(outcome)
                } else if isEditing {
                    form(model)
                } else {
                    block(model)
                }
            }
            .font(.hf(.secondary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, HfRadius.Metrics.spacing12)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("workflow-goal")
        }
    }

    // MARK: Block

    private func block(_ model: WorkflowGoalPresentation) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            label(model.label)
            if let goal = model.text {
                if naturalHeight {
                    goalText(goal)
                } else {
                    ScrollView { goalText(goal).background(ScrollChrome()) }
                        .frame(maxHeight: HfRadius.Metrics.workflowRunActivityMinimumHeight)
                }
            }
            if let assessment = model.assessmentText {
                HStack(spacing: HfRadius.Metrics.spacing8) {
                    Image(systemName: "target").accessibilityHidden(true)
                    Text(assessment)
                }
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
            }
            if let reason = model.assessmentReason {
                Text(reason).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            }
            ForEach(Array(model.evidenceRefs.enumerated()), id: \.offset) { _, ref in
                Text(ref).font(.hf(.caption)).foregroundStyle(Color.secondaryText).textSelection(.enabled)
            }
            if !model.history.isEmpty { history(model.history) }
            reviseLink(model)
        }
    }

    private func goalText(_ goal: String) -> some View {
        Text(goal).font(.hf(.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func history(_ entries: [WorkflowGoalPresentation.HistoryEntry]) -> some View {
        DisclosureGroup("Revision history") {
            if naturalHeight {
                historyEntries(entries)
            } else {
                ScrollView { historyEntries(entries).background(ScrollChrome()) }
                    .frame(maxHeight: HfRadius.Metrics.workflowRunActivityMinimumHeight)
            }
        }
    }

    private func historyEntries(_ entries: [WorkflowGoalPresentation.HistoryEntry]) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            ForEach(entries) { entry in
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                    Text("Revision \(entry.revision)").font(.hf(.secondary, weight: .semibold))
                    Text(entry.text).font(.hf(.secondary)).textSelection(.enabled)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func reviseLink(_ model: WorkflowGoalPresentation) -> some View {
        if run.canReviseGoal {
            Button("Revise goal…") { viewModel.beginGoalDraft(run: run) }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentLink)
                .disabled(viewModel.isBusy)
        } else {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                Button("Revise goal…") {}
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.tertiaryText)
                    .disabled(true)
                if let reason = model.unavailableReason {
                    Text(reason).font(.hf(.caption)).foregroundStyle(Color.tertiaryText)
                }
            }
        }
    }

    // MARK: Form

    private func form(_ model: WorkflowGoalPresentation) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            label(model.formLabel)
            TextEditor(text: Binding(get: { viewModel.goalDraft?.text ?? "" }, set: { viewModel.updateGoalDraft($0) }))
                .font(.hf(.body))
                .scrollChromeScope()
                .frame(minHeight: HfRadius.Metrics.sidebarSearchMinimumWidth)
                .accessibilityLabel("Revised workflow goal")
            if run.sharedAnswering {
                Text("The original caller can also answer. Whichever answers first is used.")
                    .font(.hf(.caption))
                    .foregroundStyle(Color.tertiaryText)
            }
            if let message = viewModel.goalRevisionError {
                (Text("Couldn't save the goal.").bold() + Text(" \(message) Your draft is preserved."))
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.dangerFG)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(HfRadius.Metrics.spacing8)
                    .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.dangerBG))
                    .accessibilityIdentifier("workflow-goal-error")
            }
            HStack(spacing: HfRadius.Metrics.spacing8) {
                Button("Cancel") { viewModel.cancelGoalDraft() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.secondaryText)
                Button("Save goal") {
                    if let draft = viewModel.goalDraft {
                        viewModel.reviseGoal(draft.text, runID: run.id, expectedRevision: draft.expectedRevision)
                    }
                }
                .buttonStyle(MonitorButtonStyle(.primary))
                .disabled(viewModel.isBusy || !run.canReviseGoal
                    || (viewModel.goalDraft?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: Answered elsewhere

    private func answeredCard(_ outcome: WorkflowInteractionReceipt) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            HStack(spacing: HfRadius.Metrics.spacing6) {
                Image(systemName: "target").accessibilityHidden(true)
                label("Goal")
            }
            WorkflowInteractionOutcomeView(receipt: outcome, savedDraft: viewModel.interactionSavedDraft,
                                           isRaceOutcome: true, showsChrome: false)
        }
        .padding(HfRadius.Metrics.spacing12)
        .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.composerFill))
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.tertiaryText)
    }
}

#if DEBUG
#Preview {
    let vm = WorkflowPreview.make(run: true)
    WorkflowGoalView(viewModel: vm, run: WorkflowRunModel(raw: [
        "workflow_run_id": .string("run"), "status": .string("running"),
        "goal": .string("Verify the release."), "goal_revision": .number(3),
        "goal_history": .array([.object(["revision": .number(2), "goal": .string("Verify.")]),
                                .object(["revision": .number(1), "goal": .string("Check.")])])
    ]))
    .frame(width: 360)
    .padding()
}
#endif
