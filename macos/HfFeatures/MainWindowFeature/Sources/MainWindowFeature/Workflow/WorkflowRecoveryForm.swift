import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowRecoveryForm

/// Recovery details remain visible across launch origins. Fresh engine eligibility controls
/// actions, while required answers and reasons stay local input requirements. Child controls
/// navigate to the root checkpoint; interrupted scheduler recovery grants no extra attempts.
/// The view reads the current VM so a stale captured run cannot retarget a user action.
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
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                HStack(alignment: .center, spacing: HfRadius.Metrics.spacing8) {
                    Text("Recovery options")
                        .font(.hf(.secondary, weight: .semibold))
                        .foregroundStyle(Color.secondaryText)
                        .accessibilityHidden(isInNamedPanel)
                    Spacer(minLength: HfRadius.Metrics.spacing8)
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.hf(.caption, weight: .medium))
                            .foregroundStyle(Color.secondaryText)
                            .frame(width: HfRadius.Metrics.recoveryCloseTarget,
                                   height: HfRadius.Metrics.recoveryCloseTarget)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close recovery options")
                    .help("Close the recovery options panel")
                }
                HStack(alignment: .top, spacing: HfRadius.Metrics.spacing10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.warningFG)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                        Text(run.question.isEmpty ? "Scheduling is paused." : run.question)
                            .font(.hf(.secondary, weight: .semibold))
                            .foregroundStyle(Color.warningFG)
                            .textSelection(.enabled)
                        if run.isSettling {
                            Text("Waiting for running branches to finish…")
                                .font(.hf(.secondary))
                                .foregroundStyle(Color.secondaryText)
                                .textSelection(.enabled)
                        }
                    }
                }
                Text("Additional instructions")
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
                WorkflowRecoveryEditor(
                    text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }),
                    isFocusRequested: isEditorFocusRequested
                )
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: HfRadius.Metrics.spacing8) {
                        recoveryControls(run: run)
                    }
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        recoveryControls(run: run)
                    }
                }
                .font(.hf(.body))
            }
            .padding(HfRadius.Metrics.recoveryBannerPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: HfRadius.Metrics.recoveryBannerCornerRadius).fill(Color.warningBG))
            .overlay {
                if !isInNamedPanel {
                    RoundedRectangle(cornerRadius: HfRadius.Metrics.recoveryBannerCornerRadius)
                        .strokeBorder(Color.recoveryBorder, lineWidth: HfRadius.Metrics.hairlineStroke)
                }
            }
        }
    }

    @ViewBuilder
    private func recoveryControls(run: WorkflowRunModel) -> some View {
        if !run.isSchedulerRecovery {
        Stepper(
            "Extra attempts: \(viewModel.additionalAttempts)",
            value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
            in: 0 ... 100
        )
            .fixedSize()
            .monospacedDigit()
            .disabled(!run.permitsMonitor("additional_attempts", fallback: run.allowsMonitorControl) || viewModel.isBusy)
        if run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false {
            Button("Continue with one more retry") { viewModel.continueWithOneMoreRetry() }
                .buttonStyle(MonitorButtonStyle(.glass))
                .disabled(viewModel.isBusy || !run.canSubmitContinuation(run.recoveryCommand, instructions: viewModel.instructions)
                          || !run.permitsMonitor("additional_attempts", fallback: run.allowsMonitorControl))
        }
        }
        if run.raw["optional_review_skip_available"]?.boolValue == true {
            Button("Proceed without optional reviewer") {
                viewModel.control("resume", allowOptionalReviewSkip: true)
            }
            .buttonStyle(MonitorButtonStyle(.glass))
            .disabled(viewModel.isBusy || !run.canSkipOptionalReview
                      || !run.canSubmitContinuation("resume", instructions: viewModel.instructions))
        }
        Button(run.recoveryCommand == "recover" ? "Recover" : "Resume") { viewModel.control(run.recoveryCommand) }
            .buttonStyle(MonitorButtonStyle(.primary))
            .disabled(viewModel.isBusy || !run.canSubmitContinuation(run.recoveryCommand, instructions: viewModel.instructions))
        if let reason = run.monitorReason(run.recoveryCommand) {
            Text(reason).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        }
        if run.parentRunID != nil {
            Button("Open root workflow") { viewModel.openRun(run.rootRunID) }
                .buttonStyle(QuietButtonStyle())
        }
    }
}

#if DEBUG
#Preview("Recovery form - light") {
    WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), onClose: {})
        .frame(width: HfRadius.Metrics.workflowNarrowPreviewWidth)
        .preferredColorScheme(.light)
}

#Preview("Recovery form - dark") {
    WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), onClose: {})
        .frame(width: HfRadius.Metrics.workflowNarrowPreviewWidth)
        .preferredColorScheme(.dark)
}

#Preview("Recovery form - long question, settling") {
    let vm = WorkflowPreview.makeLongQuestionRun()
    var raw = vm.selectedRun?.raw ?? [:]
    raw["settling"] = .bool(true)
    vm.selectedRun = WorkflowRunModel(raw: raw)
    return ScrollView {
        WorkflowRecoveryForm(viewModel: vm, onClose: {})
            .frame(width: HfRadius.Metrics.formPreviewWidth)
    }
    .preferredColorScheme(.dark)
}

#Preview("Recovery form - long question, narrow, light") {
    ScrollView {
        WorkflowRecoveryForm(viewModel: WorkflowPreview.makeLongQuestionRun(), onClose: {})
            .frame(width: HfRadius.Metrics.formPreviewWidth)
    }
    .preferredColorScheme(.light)
}
#endif
