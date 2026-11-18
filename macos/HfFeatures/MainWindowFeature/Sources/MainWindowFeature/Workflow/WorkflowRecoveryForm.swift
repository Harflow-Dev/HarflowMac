import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowRecoveryForm

/// Recovery details remain visible across launch origins. Fresh engine eligibility controls
/// actions, while required answers and reasons stay local input requirements. Child controls
/// navigate to the root checkpoint; interrupted scheduler recovery grants no extra attempts.
/// The view reads the current VM so a stale captured run cannot retarget a user action.
struct WorkflowRecoveryForm<VM: WorkflowViewModel>: View {
    /// The form's two presentations: the floating overlay card (Parallel) and the Graph recovery pane section.
    enum Style: Equatable {
        case overlay
        case pane
    }

    var viewModel: VM
    var style = Style.overlay
    /// An explicit-open focus request; the visible editor consumes the pending one.
    var focusRequest = WorkflowRecoveryFocusRequest()
    var onFocusConsumed: () -> Void = {}
    /// The owned host supplies stationary panel chrome and the named accessibility group.
    /// Standalone forms retain their border and accessible visible heading.
    var isInNamedPanel = false
    /// Presentation-only dismissal of the overlay. It never issues a control command and never
    /// clears the instructions or the attempt selection. The pane has no close.
    var onClose: () -> Void = {}

    var body: some View {
        if let run = viewModel.selectedRun {
            switch style {
            case .overlay: overlayBody(run)
            case .pane: paneBody(run)
            }
        }
    }

    // MARK: Overlay

    private func overlayBody(_ run: WorkflowRunModel) -> some View {
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
                    Text(WorkflowRecoveryPanePresentation.question(for: run))
                        .font(.hf(.secondary, weight: .semibold))
                        .foregroundStyle(Color.warningFG)
                        .textSelection(.enabled)
                    settlingLine(run)
                }
            }
            Text("Additional instructions")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
            editor
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: HfRadius.Metrics.spacing8) {
                    overlayControls(run: run)
                }
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                    overlayControls(run: run)
                }
            }
            .font(.hf(.body))
            sharedAnsweringNote(run)
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

    @ViewBuilder
    private func overlayControls(run: WorkflowRunModel) -> some View {
        if !run.isSchedulerRecovery {
            Stepper(
                "Extra attempts: \(viewModel.additionalAttempts)",
                value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
                in: 0 ... 100
            )
            .fixedSize()
            .monospacedDigit()
            .disabled(!attemptsAllowed(run) || viewModel.isBusy)
            if hasExhaustedEdges(run) {
                Button("Continue with one more retry") { viewModel.continueWithOneMoreRetry() }
                    .buttonStyle(MonitorButtonStyle(.glass))
                    .disabled(!canRetry(run))
            }
        }
        if run.raw["optional_review_skip_available"]?.boolValue == true {
            Button("Proceed without optional reviewer") {
                viewModel.control("resume", allowOptionalReviewSkip: true)
            }
            .buttonStyle(MonitorButtonStyle(.glass))
            .disabled(!canSkipReview(run))
        }
        Button(run.recoveryCommand == "recover" ? "Recover" : "Resume") { viewModel.control(run.recoveryCommand) }
            .buttonStyle(MonitorButtonStyle(.primary))
            .disabled(!canResume(run))
        if let reason = run.monitorReason(run.recoveryCommand) {
            Text(reason).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
        }
        if run.parentRunID != nil {
            Button("Open root workflow") { viewModel.openRun(run.rootRunID) }
                .buttonStyle(QuietButtonStyle())
        }
    }

    // MARK: Pane

    /// Section 1 of the approved `workflow-run/recovery` state: failure sentence, instructions, extra attempts and the
    /// stacked actions, with the section's own bottom border.
    private func paneBody(_ run: WorkflowRunModel) -> some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            HStack(alignment: .top, spacing: HfRadius.Metrics.spacing8) {
                glyph(for: run)
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing2) {
                    Text(WorkflowRecoveryPanePresentation.question(for: run))
                        .font(.hf(.body))
                        .foregroundStyle(Color.primaryText)
                        .textSelection(.enabled)
                    settlingLine(run)
                }
            }
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing6) {
                Text("Additional instructions")
                    .font(.hf(.secondary, weight: .medium))
                    .foregroundStyle(Color.secondaryText)
                editor
            }
            if !run.isSchedulerRecovery { attemptsRow(run) }
            VStack(spacing: HfRadius.Metrics.spacing8) { paneButtons(run) }
            if let reason = run.monitorReason(run.recoveryCommand) {
                Text(reason).font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
            if run.parentRunID != nil {
                Button("Open root workflow") { viewModel.openRun(run.rootRunID) }
                    .buttonStyle(QuietButtonStyle())
            }
            sharedAnsweringNote(run)
        }
        .padding(.horizontal, HfRadius.Metrics.spacing16)
        .padding(.vertical, HfRadius.Metrics.spacing12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-recovery-pane-form")
    }

    @ViewBuilder
    private func glyph(for run: WorkflowRunModel) -> some View {
        switch WorkflowRecoveryPanePresentation.glyph(for: run) {
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(Color.failedRed).accessibilityHidden(true)
        case .attention:
            StatusGlyphView(.hand).foregroundStyle(Color.warningFG).accessibilityHidden(true)
        }
    }

    private func attemptsRow(_ run: WorkflowRunModel) -> some View {
        HStack(alignment: .center, spacing: HfRadius.Metrics.spacing8) {
            Text("Extra attempts").font(.hf(.body))
            Spacer(minLength: HfRadius.Metrics.zero)
            RecoveryAttemptsStepper(
                value: Binding(get: { viewModel.additionalAttempts }, set: { viewModel.additionalAttempts = $0 }),
                range: 0 ... 100
            )
            .disabled(!attemptsAllowed(run) || viewModel.isBusy)
        }
    }

    @ViewBuilder
    private func paneButtons(_ run: WorkflowRunModel) -> some View {
        if !run.isSchedulerRecovery, hasExhaustedEdges(run) {
            Button { viewModel.continueWithOneMoreRetry() } label: {
                Text("Continue with one more retry").frame(maxWidth: .infinity)
            }
            .buttonStyle(MonitorButtonStyle(.glass))
            .disabled(!canRetry(run))
        }
        if run.raw["optional_review_skip_available"]?.boolValue == true {
            Button { viewModel.control("resume", allowOptionalReviewSkip: true) } label: {
                Text("Proceed without optional reviewer").frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle(isFilled: false))
            .disabled(!canSkipReview(run))
        }
        Button { viewModel.control(run.recoveryCommand) } label: {
            Text(run.recoveryCommand == "recover" ? "Recover" : "Resume").frame(maxWidth: .infinity)
        }
        .buttonStyle(MonitorButtonStyle(.primary))
        .disabled(!canResume(run))
    }

    // MARK: Shared

    private var editor: some View {
        WorkflowRecoveryEditor(
            text: Binding(get: { viewModel.instructions }, set: { viewModel.instructions = $0 }),
            focusRequest: focusRequest,
            onFocusConsumed: onFocusConsumed
        )
    }

    @ViewBuilder
    private func settlingLine(_ run: WorkflowRunModel) -> some View {
        if run.isSettling {
            Text("Waiting for running branches to finish…")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func sharedAnsweringNote(_ run: WorkflowRunModel) -> some View {
        if run.sharedAnswering {
            Text("The original caller can also answer. Whichever answers first is used.")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
        }
    }

    private func hasExhaustedEdges(_ run: WorkflowRunModel) -> Bool {
        run.raw["exhausted_retry_edges"]?.arrayValue?.isEmpty == false
    }

    private func attemptsAllowed(_ run: WorkflowRunModel) -> Bool {
        run.permitsMonitor("additional_attempts", fallback: run.allowsMonitorControl)
    }

    private func canRetry(_ run: WorkflowRunModel) -> Bool {
        !viewModel.isBusy && run.canSubmitContinuation(run.recoveryCommand, instructions: viewModel.instructions)
            && attemptsAllowed(run)
    }

    private func canSkipReview(_ run: WorkflowRunModel) -> Bool {
        !viewModel.isBusy && run.canSkipOptionalReview
            && run.canSubmitContinuation("resume", instructions: viewModel.instructions)
    }

    private func canResume(_ run: WorkflowRunModel) -> Bool {
        !viewModel.isBusy && run.canSubmitContinuation(run.recoveryCommand, instructions: viewModel.instructions)
    }
}

// MARK: - RecoveryAttemptsStepper

/// The approved `.hd-stepper`: one 28 pt rounded, bordered group of plain 26 pt buttons around a value at least 40 pt wide,
/// separated by hairlines. The caller owns the binding and bounds; only legal adjacent values are offered.
private struct RecoveryAttemptsStepper: View {
    @Binding var value: Int
    let range: ClosedRange<Int>

    private static let groupHeight: CGFloat = 28
    private static let buttonSize: CGFloat = 26
    private static let valueMinimumWidth: CGFloat = 40

    var body: some View {
        HStack(spacing: HfRadius.Metrics.zero) {
            stepButton(increment: false)
            divider
            Text(value.formatted())
                .font(.hf(.body))
                .monospacedDigit()
                .foregroundStyle(Color.primaryText)
                .frame(minWidth: Self.valueMinimumWidth, minHeight: Self.buttonSize)
                .accessibilityLabel("Extra attempts, \(value)")
            divider
            stepButton(increment: true)
        }
        .frame(height: Self.groupHeight)
        .background(RoundedRectangle(cornerRadius: HfRadius.row).fill(Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: HfRadius.row).strokeBorder(Color.cardBorder, lineWidth: HfRadius.Metrics.hairlineStroke))
        .clipShape(RoundedRectangle(cornerRadius: HfRadius.row))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Extra attempts")
    }

    private var divider: some View {
        Rectangle().fill(Color.hairline).frame(width: HfRadius.Metrics.hairlineStroke).accessibilityHidden(true)
    }

    private func stepButton(increment: Bool) -> some View {
        let next = CompactStepper.adjacentValue(value, in: range, step: 1, increment: increment)
        return Button {
            if let next { value = next }
        } label: {
            Image(systemName: increment ? "plus" : "minus")
                .font(.hf(.secondary))
                .foregroundStyle(Color.secondaryText)
                .frame(width: Self.buttonSize, height: Self.buttonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(next == nil)
        .accessibilityLabel(increment ? "More extra attempts" : "Fewer extra attempts")
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

#Preview("Recovery pane form - light") {
    ScrollView {
        WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), style: .pane)
            .frame(width: HfRadius.Metrics.workflowRunRecoveryPanelIdealWidth)
    }
    .background(Color.windowBG)
    .preferredColorScheme(.light)
}

#Preview("Recovery pane form - long question, dark") {
    ScrollView {
        WorkflowRecoveryForm(viewModel: WorkflowPreview.makeLongQuestionRun(), style: .pane)
            .frame(width: HfRadius.Metrics.workflowRunRecoveryPanelIdealWidth)
    }
    .background(Color.windowBG)
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
