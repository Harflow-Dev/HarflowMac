import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowRecoveryOverlayHost

/// The bounded, non-blocking recovery overlay composition (user amendment over SPEC §6.4):
/// the existing recovery form floats top-trailing over `WorkflowRunPanes` — below the
/// diagnostics strip and its divider, never over it — with no backdrop, no layout reservation
/// and no hit target outside its own bounds, so the underlying panes stay interactive and
/// their geometry is identical open, closed and reopened. Long questions and controls scroll
/// inside the panel; they never grow it past the pane or push the workflow. Visibility is
/// local presentation only: the automatic first eligible loaded open, the eligibility-driven
/// hide and explicit dismissal live in `WorkflowRecoveryOverlayPresentation`.
struct WorkflowRecoveryOverlayHost<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @Binding var presentation: WorkflowRecoveryOverlayPresentation
    /// Presentation-only follow-up on explicit dismissal: the caller may return focus to the
    /// eligible badge, best-effort. Auto-hide never calls it.
    var onExplicitClose: () -> Void
    @State private var contentHeight = PbRadius.Metrics.recoveryPanelInitialHeight

    private var eligibleRunID: String? {
        WorkflowRecoveryOverlayPresentation.eligibleRunID(
            run: viewModel.selectedRun,
            initialLoadingKind: viewModel.initialLoadingKind,
            initialLoadFailed: viewModel.initialLoadFailed
        )
    }

    var body: some View {
        GeometryReader { pane in
            if presentation.isVisible(runID: eligibleRunID) {
                panel(paneSize: pane.size)
            }
        }
        .onAppear { presentation.syncEligibility(runID: eligibleRunID) }
        .onChange(of: eligibleRunID) { _, runID in
            presentation.syncEligibility(runID: runID)
        }
    }

    /// The panel itself: bounded by the pane viewport, padded off its edges, anchored
    /// top-trailing, with the scoped Escape monitor on its own bounds.
    private func panel(paneSize: CGSize) -> some View {
        let width = min(PbRadius.Metrics.recoveryPanelIdealWidth,
                        max(PbRadius.Metrics.zero, paneSize.width - 2 * PbRadius.Metrics.recoveryPanelInset))
        let height = min(contentHeight, max(PbRadius.Metrics.zero, paneSize.height - 2 * PbRadius.Metrics.recoveryPanelInset))
        return WorkflowRecoveryPanelContainer(onEscape: dismissExplicitly) {
            ScrollView {
                WorkflowRecoveryForm(
                    viewModel: viewModel,
                    isEditorFocusRequested: presentation.isEditorFocusRequested,
                    isInNamedPanel: true,
                    onClose: dismissExplicitly
                )
                .fixedSize(horizontal: false, vertical: true)
                // The document probe (§6.3): inside the recovery panel's own document — the
                // panel's bounds, geometry measurement and Escape handling are unchanged.
                .background(ScrollChrome())
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if height.isFinite, height > PbRadius.Metrics.zero, contentHeight != height { contentHeight = height }
                }
            }
            .background(Color.warningBG)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recovery options")
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: PbRadius.Metrics.recoveryBannerCornerRadius)
                .strokeBorder(Color.recoveryBorder, lineWidth: PbRadius.Metrics.hairlineStroke)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .shadow(color: Color.recoveryShadow,
                radius: PbRadius.Metrics.recoveryPanelShadowRadius,
                y: PbRadius.Metrics.recoveryPanelShadowOffsetY)
        .padding(.top, PbRadius.Metrics.recoveryPanelInset)
        .padding(.trailing, PbRadius.Metrics.recoveryPanelInset)
        .frame(width: paneSize.width, height: paneSize.height, alignment: .topTrailing)
    }

    /// Explicit dismissal only: presentation state plus the caller's best-effort badge focus.
    /// No control command, no selection change, no input clearing.
    private func dismissExplicitly() {
        presentation.closeExplicitly()
        onExplicitClose()
    }
}

// MARK: - WorkflowRecoveryOverlayLifecycle

/// Reconciles eligibility on the persistent screen, including while the run host is unmounted.
struct WorkflowRecoveryOverlayLifecycle: ViewModifier {
    @Binding var presentation: WorkflowRecoveryOverlayPresentation
    let eligibleRunID: String?

    func body(content: Content) -> some View {
        content
            .onAppear { presentation.syncEligibility(runID: eligibleRunID) }
            .onChange(of: eligibleRunID) { _, runID in presentation.syncEligibility(runID: runID) }
            .onDisappear { presentation.syncEligibility(runID: nil) }
    }
}

// MARK: - WorkflowRecoveryBadge

/// The run header's honest status badge, wrapped in a presentation-only open action exactly
/// while the recovery form is eligible. The badge keeps its unchanged status label, mapping
/// and VoiceOver announcement; the button only adds help and a hint that it opens the recovery
/// options. It is open-only, never a toggle — an already-open panel stays open — and an
/// ineligible run renders the plain badge with exactly its previous noninteractive
/// semantics, never a disabled fake button.
struct WorkflowRecoveryBadge: View {
    var run: WorkflowRunModel
    var isEligible: Bool
    var focus: FocusState<Bool>.Binding
    var onOpen: () -> Void

    private var badge: some View {
        StatusBadge(
            status: .other(run.status),
            presentationOverride: WorkflowRunStatusBadge.presentation(status: run.status, isSettling: run.isSettling)
        )
    }

    var body: some View {
        if isEligible {
            Button(action: onOpen) { badge }
                .buttonStyle(.plain)
                .focused(focus)
                .help("Open recovery options")
                .accessibilityHint("Opens the recovery options panel.")
        } else {
            badge
        }
    }
}

#if DEBUG

// MARK: - WorkflowRecoveryOverlayPreview

private struct WorkflowRecoveryOverlayPreview: View {
    @State private var presentation = WorkflowRecoveryOverlayPresentation()
    @State private var viewModel: WorkflowVM

    init(longQuestion: Bool = false) {
        _viewModel = State(initialValue: longQuestion ? WorkflowPreview.makeLongQuestionRun() : WorkflowPreview.make(run: true))
    }

    var body: some View {
        ZStack {
            Color.cardFill
            WorkflowRecoveryOverlayHost(viewModel: viewModel, presentation: $presentation, onExplicitClose: {})
        }
    }
}

#Preview("Recovery overlay - light") {
    WorkflowRecoveryOverlayPreview()
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.workflowCanvasPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Recovery overlay - dark") {
    WorkflowRecoveryOverlayPreview()
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.workflowCanvasPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Recovery overlay - long question, light") {
    WorkflowRecoveryOverlayPreview(longQuestion: true)
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Recovery overlay - long question, dark") {
    WorkflowRecoveryOverlayPreview(longQuestion: true)
        .frame(width: PbRadius.Metrics.workflowNarrowPreviewWidth, height: PbRadius.Metrics.taskDetailNarrowPreviewHeight)
        .preferredColorScheme(.dark)
}

#Preview("Recovery overlay - narrow, light") {
    WorkflowRecoveryOverlayPreview(longQuestion: true)
        .frame(width: PbRadius.Metrics.formPreviewWidth, height: PbRadius.Metrics.workflowCanvasPreviewHeight)
        .preferredColorScheme(.light)
}

#Preview("Recovery overlay - narrow, dark") {
    WorkflowRecoveryOverlayPreview(longQuestion: true)
        .frame(width: PbRadius.Metrics.formPreviewWidth, height: PbRadius.Metrics.workflowCanvasPreviewHeight)
        .preferredColorScheme(.dark)
}

// MARK: - WorkflowRecoveryBadgePreviewHarness

private struct WorkflowRecoveryBadgePreviewHarness: View {
    @FocusState private var focus: Bool

    var body: some View {
        let vm = WorkflowPreview.make(run: true)
        if let run = vm.selectedRun {
            HStack(spacing: PbRadius.Metrics.spacing16) {
                WorkflowRecoveryBadge(run: run, isEligible: true, focus: $focus, onOpen: {})
                WorkflowRecoveryBadge(run: run, isEligible: false, focus: $focus, onOpen: {})
            }
            .padding(PbRadius.Metrics.spacing16)
        }
    }
}

#Preview("Recovery badge - eligible and plain, light") {
    WorkflowRecoveryBadgePreviewHarness().preferredColorScheme(.light)
}

#Preview("Recovery badge - eligible and plain, dark") {
    WorkflowRecoveryBadgePreviewHarness().preferredColorScheme(.dark)
}
#endif
