import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowDecisionFallback

/// The decision line's honest fallback: "Waiting for the first step" appears only while the run
/// is still starting/running with no reason and no worker step — never beside an attention or
/// error state, and never after a step has started. The run's own reported reason wins whenever
/// one exists. Pure and testable.
enum WorkflowDecisionFallback {
    static let waitingForFirstStep = "Waiting for the first step"

    static func text(status: String, reason: String, hasWorkerStep: Bool, recoveryQuestion: String? = nil) -> String? {
        if let recoveryQuestion,
           reason.trimmingCharacters(in: .whitespacesAndNewlines) == recoveryQuestion.trimmingCharacters(in: .whitespacesAndNewlines) {
            return nil
        }
        if !reason.isEmpty { return reason }
        if hasWorkerStep { return nil }
        if ["starting", "running"].contains(status) { return waitingForFirstStep }
        return nil
    }
}

/// The existing recovery eligibility, shared by the banner and its duplicate-reason suppression.
enum WorkflowRecoveryPresentation {
    static func showsRecovery(status: String, allowsMonitorControl: Bool, isDelegation: Bool) -> Bool {
        allowsMonitorControl && (["needs_attention", "paused", "needs_input"].contains(status)
            || (isDelegation && status == "failed"))
    }

    static func showsRecovery(_ run: WorkflowRunModel) -> Bool {
        showsRecovery(status: run.status, allowsMonitorControl: run.allowsMonitorControl, isDelegation: run.isDelegation)
    }
}

// MARK: - WorkflowRunStatus

struct WorkflowRunStatus<VM: WorkflowViewModel>: View {
    var viewModel: VM
    /// Purely presentational: whether the non-blocking recovery panel is actually showing the
    /// recovery question right now. Direct callers and previews keep the default `false`, which
    /// renders exactly the pre-amendment strip. It never changes eligibility, fallback logic or
    /// any action — it only hides the painting and accessibility of a duplicate reason-only
    /// row while the panel shows the same question.
    var isRecoveryPanelVisible = false
    @State private var showsDecision = false

    var body: some View {
        if let run = viewModel.selectedRun {
            VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
                decision(run)
                WorkflowRunDiagnostics(run: run)
                if run.raw["kind"]?.stringValue == "builder", run.status == "completed" {
                    if run.isBuilderProposal {
                        Button("Apply proposal") { viewModel.applyAgentProposal() }.buttonStyle(MonitorButtonStyle(.glass))
                    } else {
                        Button("Open generated draft") { viewModel.openWorkflowEditor(run.name) }.buttonStyle(MonitorButtonStyle(.glass))
                    }
                }
                if viewModel.canReturnToCanvas {
                    Button("Return to canvas") { viewModel.returnToCanvas() }.buttonStyle(MonitorButtonStyle(.glass))
                }
                if viewModel.selectedActivationID != nil {
                    Button("Show latest steps") { viewModel.selectActivation(nil) }.buttonStyle(MonitorButtonStyle(.glass))
                }
            }
.padding(.horizontal, PbRadius.Metrics.spacing16)
.padding(.vertical, PbRadius.Metrics.spacing10)
        }
    }

    @ViewBuilder
    private func decision(_ run: WorkflowRunModel) -> some View {
        let last = WorkflowJSON.objects(run.raw["decisions"]).last
        let deciding = run.activations.contains { $0["role"]?.stringValue == "orchestrator" && $0["status"]?.stringValue == "running" }
        // Only proven-prestart logic decides whether the waiting line is honest: a worker step
        // that has started, an attention/error state, or a reported reason each withdraw it.
        // The fallback is computed independently of the recovery panel's visibility, so the
        // row keeps its measured layout in every panel state; the open panel hides only the
        // painting of a duplicate question (below).
        let fallback = WorkflowDecisionFallback.text(
            status: run.status,
            reason: run.reason,
            hasWorkerStep: !WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: run.activations)
        )
        let lastReason = last?["reason"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let lineText = deciding ? "Orchestrator is choosing the next step…" : (lastReason ?? fallback)
        // Duplicate suppression is painting-only: while the panel actually shows the recovery
        // question, a reason-only line that repeats it stays in layout but is not painted or
        // spoken — closing the panel reveals it without inserting a row or shifting the panes.
        // Durable decision history and its "Show more" are never hidden.
        let trimmedQuestion = run.question.trimmingCharacters(in: .whitespacesAndNewlines)
        let hidesDuplicateQuestion = !deciding
            && lastReason == nil
            && lineText != nil
            && isRecoveryPanelVisible
            && !trimmedQuestion.isEmpty
            && lineText?.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedQuestion
        if deciding || lineText != nil {
        HStack(spacing: PbRadius.Metrics.spacing8) {
            if deciding {
                RunningSpinner()
            } else if lineText != nil {
                Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.secondaryText)
            }
            if let lineText {
                Text(lineText)
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !deciding, let reason = lastReason {
                Button("Show more") { showsDecision = true }
                    .buttonStyle(.link)
                    .fixedSize()
                    .popover(isPresented: $showsDecision) {
                        ScrollView {
                            Text(reason)
.font(.pb(.body))
.textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
.padding(PbRadius.Metrics.spacing16)
                                // The document probe (§6.4): inside the decision popover's own
                                // document.
                                .background(ScrollChrome())
                        }.frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.activityPreviewWidth)
                    }
            }
        }
        .opacity(hidesDuplicateQuestion ? 0 : 1)
        .accessibilityHidden(hidesDuplicateQuestion)
    }
        }
}

#if DEBUG
#Preview("Workflow decisions and checklist - light") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: PbRadius.Metrics.toolbarPreviewWidth).preferredColorScheme(.light)
}

#Preview("Workflow decisions and checklist - dark") {
    WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true)).frame(width: PbRadius.Metrics.toolbarPreviewWidth).preferredColorScheme(.dark)
}

#Preview("Workflow decisions and checklist - narrow, long question") {
    WorkflowRunStatus(viewModel: WorkflowPreview.makeLongQuestionRun()).frame(width: PbRadius.Metrics.toolRowPreviewWidth)
}

#Preview("Workflow decisions - duplicate reason hidden only while the panel is open") {
    HStack(spacing: PbRadius.Metrics.zero) {
        WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true))
            .frame(width: PbRadius.Metrics.toolRowPreviewWidth)
        Divider()
        WorkflowRunStatus(viewModel: WorkflowPreview.make(run: true), isRecoveryPanelVisible: true)
            .frame(width: PbRadius.Metrics.toolRowPreviewWidth)
    }
}
#endif
