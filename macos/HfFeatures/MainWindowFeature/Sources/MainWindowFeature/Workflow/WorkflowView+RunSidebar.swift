import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - Run sidebar

extension WorkflowView {
    static func admitsCallerApprovals(_ run: WorkflowRunModel) -> Bool {
        CallerApprovalPanel.containsOptIn(.object(run.raw)) || (run.raw["approval_summary"]?["pending_count"]?.intValue ?? 0) > 0
    }

    /// The default run sidebar. With `showsRecovery` it is re-headed as the recovery pane: a fixed head, then the
    /// recovery section and the goal block, then the same sections in the same order. It is one instance either way, so
    /// the approvals poller and the scroll view keep their identity when recovery eligibility changes.
    @ViewBuilder func defaultRunSidebar(showsRecovery: Bool, isHiddenBehindSelection: Bool = false) -> some View {
        if let run = viewModel.selectedRun {
            VStack(spacing: HfRadius.Metrics.zero) {
                if showsRecovery {
                    WorkflowRecoveryPaneHead(run: run)
                    Divider()
                }
                ScrollView {
                    VStack(spacing: HfRadius.Metrics.zero) {
                        if showsRecovery {
                            WorkflowRecoveryForm(viewModel: viewModel, style: .pane, focusRequest: recoveryFocus,
                                                 onFocusConsumed: { recoveryFocus.consume() })
                            if WorkflowGoalPresentation.showsBlock(run: run) {
                                WorkflowGoalView(viewModel: viewModel, run: run)
                                    .padding(HfRadius.Metrics.spacing16)
                            }
                        }
                        runSidebarSections(run: run, showsRecovery: showsRecovery)
                        Divider()
                    }
                    // The document probe (§6.4): inside the run inspector's own document, so it can only
                    // ever target this outer scroll view — never a nested disclosure's.
                    .background(ScrollChrome())
                    .background(WorkflowRunSidebarScrollMarker(isHidden: isHiddenBehindSelection))
                }
            }
            .accessibilityIdentifier("workflow-run-inspector")
            .background(showsRecovery ? TaskScreenStyle.Colors.pageBackground.color : Color.cardFill)
        }
    }

    @ViewBuilder
    func runSidebarSections(run: WorkflowRunModel, showsRecovery: Bool) -> some View {
        if run.parentRunID != nil {
            Text("Child workflow · Plan and checklist belong to this run")
                .font(.hf(.caption))
                .foregroundStyle(Color.tertiaryText)
                .padding(HfRadius.Metrics.spacing16)
        }
        if run.sessionOwnerRunID != run.id {
            Button("Open owning orchestrator") { viewModel.openRun(run.sessionOwnerRunID) }
                .buttonStyle(QuietButtonStyle())
                .padding(.horizontal, HfRadius.Metrics.spacing16)
        }
        if Self.admitsCallerApprovals(run) {
            CallerApprovalPanel(workflowRunID: run.id,
                                polls: (viewMode != "Graph" || viewModel.runSidebar.isDefault)
                                    && ["running", "needs_attention", "needs_input"].contains(run.status))
        }
        WorkflowChildLinks(groups: WorkflowChildLinkGroup.build(run: run), onOpen: viewModel.openRun)
            .padding(.horizontal, HfRadius.Metrics.spacing16)
            .padding(.vertical, HfRadius.Metrics.spacing4)
        if let assignment = run.raw["prompt"]?.stringValue, !assignment.isEmpty {
            DisclosureGroup(run.parentRunID == nil ? "Original request" : "Assignment for this child") {
                ScrollView {
                    ReadingMarkdownView(text: assignment)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, HfRadius.Metrics.spacing6)
                        // The document probe (§6.4): inside this nested disclosure's own
                        // document, never the outer run inspector's.
                        .background(ScrollChrome())
                }.frame(maxHeight: HfRadius.Metrics.workflowRunActivityMinimumHeight)
            }
            .font(.hf(.secondary, weight: .medium))
            .padding(HfRadius.Metrics.spacing16)
            // Native disclosure triangles extend before their label's layout origin.
            .padding(.leading, HfRadius.Metrics.spacing8)
        }
        if !showsRecovery, WorkflowGoalPresentation.showsBlock(run: run) {
            WorkflowGoalView(viewModel: viewModel, run: run)
                .padding(HfRadius.Metrics.spacing16)
                .padding(.leading, HfRadius.Metrics.spacing8)
        }
        WorkflowRunPlan(run: run)
            .padding(HfRadius.Metrics.spacing16)
            .padding(.leading, HfRadius.Metrics.spacing8)
        if let plan = run.technicalPlan {
            DisclosureGroup("Technical plan") {
                ScrollView {
                    ReadingMarkdownView(text: plan)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, HfRadius.Metrics.spacing6)
                        // The document probe (§6.4): inside this nested disclosure's own
                        // document, never the outer run inspector's.
                        .background(ScrollChrome())
                }.frame(maxHeight: HfRadius.Metrics.formPreviewWidth)
            }
            .font(.hf(.secondary, weight: .medium))
            .padding(HfRadius.Metrics.spacing16)
            .padding(.leading, HfRadius.Metrics.spacing8)
        }
    }
}
