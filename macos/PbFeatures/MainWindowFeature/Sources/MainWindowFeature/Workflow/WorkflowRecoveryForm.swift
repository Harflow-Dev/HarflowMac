import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRecoveryForm

/// The existing attempt-limit recovery form (SPEC §6.4), extracted unchanged out of document
/// flow into the non-blocking floating panel (user amendment): the existing question (or the
/// existing "Scheduling is paused." fallback) and settling line, the compact growing multiline
/// editor, the 0…100 extra-attempts stepper, one-more-retry, the optional reviewer consent and
/// the Resume/Recover primary with its identical busy/settling/requires-answer guards. Nothing
/// is invented and no guard changes; the only additions are the close control and the
/// accessible recovery title. The view takes the VM, never a captured run, so every control
/// acts on the current selected run through the existing VM bindings.
struct WorkflowRecoveryForm<VM: WorkflowViewModel>: View {
    var viewModel: VM
    /// An explicit-open editor focus request passed through to the editor; `false` keeps the
    /// regular editor contract.
    var isEditorFocusRequested = false
    /// The owned host supplies stationary panel chrome and the named accessibility group.
    /// Standalone forms retain their border and accessible visible heading.
    var isInNamedPanel = false
    /// Presentation-only dismissal. It never issues a control command and never clears the
    /// instructions or the attempt selection.
    var onClose: () -> Void

    var body: some View {
        if let run = viewModel.selectedRun {
            let missingAnswer = run.requiresAnswer && viewModel.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                HStack(alignment: .center, spacing: PbRadius.Metrics.spacing8) {
                    Text("Recovery options")
                        .font(.pb(.secondary, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityHidden(isInNamedPanel)
                    Spacer(minLength: PbRadius.Metrics.spacing8)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.pb(.caption, weight: .medium))
                            .foregroundStyle(Color.secondaryText)
                            .frame(width: PbRadius.Metrics.recoveryCloseTarget,
                                   height: PbRadius.Metrics.recoveryCloseTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close recovery options")
                    .help("Close the recovery options panel")
                }
                HStack(alignment: .top, spacing: PbRadius.Metrics.spacing10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningFG)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                        Text(run.question.isEmpty ? "Scheduling is paused." : run.question)
                            .font(.pb(.secondary, weight: .semibold))
                            .foregroundStyle(Color.warningFG)
                            .textSelection(.enabled)
                        if run.isSettling {
                            Text("Waiting for running branches to finish…")
                                .font(.pb(.secondary))
                                .foregroundStyle(Color.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("Additional instructions")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                WorkflowRecoveryEditor(
                    text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }),
                    isFocusRequested: isEditorFocusRequested
                )
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: PbRadius.Metrics.spacing8) {
                        recoveryControls(run: run, missingAnswer: missingAnswer)
                    }
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
                        recoveryControls(run: run, missingAnswer: missingAnswer)
                    }
                }
                .font(.pb(.body))
            }
            .padding(PbRadius.Metrics.recoveryBannerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius).fill(Color.warningBG))
            .overlay {
                if !isInNamedPanel {
                    RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius)
                        .strokeBorder(Color.recoveryBorder, lineWidth: PbRadius.Metrics.hairlineStroke)
                }
            }
        }
    }

    @ViewBuilder
    private func recoveryControls(run: WorkflowRunModel, missingAnswer: Bool) -> some View {
        Stepper(
            "Extra attempts: \(viewModel.additionalAttempts)",
            value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
            in: 0 ... 100
        )
            .fixedSize()
            .monospacedDigit()
        if run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false {
            Button("Continue with one more retry") { viewModel.continueWithOneMoreRetry() }
                .buttonStyle(MonitorButtonStyle(.glass))
                .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
        }
        if run.canSkipOptionalReview {
            Button("Proceed without optional reviewer") {
                viewModel.control("resume", allowOptionalReviewSkip: true)
            }
            .buttonStyle(MonitorButtonStyle(.glass))
            .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
        }
        Button(run.status == "failed" ? "Recover" : "Resume") { viewModel.control(run.status == "failed" ? "recover" : "resume") }
            .buttonStyle(MonitorButtonStyle(.primary))
            .disabled(viewModel.isBusy || run.isSettling || missingAnswer)
    }
}

#if DEBUG
#Preview("Recovery form - light") {
    WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), onClose: {})
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth)
        .preferredColorScheme(.light)
}

#Preview("Recovery form - dark") {
    WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), onClose: {})
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth)
        .preferredColorScheme(.dark)
}

#Preview("Recovery form - long question, settling") {
    let vm = WorkflowPreview.makeLongQuestionRun()
    var raw = vm.selectedRun?.raw ?? [:]
    raw["settling"] = .bool(true)
    vm.selectedRun = WorkflowRunModel(raw: raw)
    return ScrollView {
        WorkflowRecoveryForm(viewModel: vm, onClose: {})
            .frame(width: PbRadius.Metrics.formPreviewWidth)
    }
    .preferredColorScheme(.dark)
}

#Preview("Recovery form - long question, narrow, light") {
    ScrollView {
        WorkflowRecoveryForm(viewModel: WorkflowPreview.makeLongQuestionRun(), onClose: {})
            .frame(width: PbRadius.Metrics.formPreviewWidth)
    }
    .preferredColorScheme(.light)
}
#endif
