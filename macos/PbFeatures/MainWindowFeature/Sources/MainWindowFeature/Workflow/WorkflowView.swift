import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - WorkflowView

struct WorkflowView<VM: WorkflowViewModel>: View {
    @Environment(\.viewEvent) var viewEvent
    @State var viewModel: VM
    private let builderTaskView: ((String, String) -> AnyView)?
    @AppStorage("workflowViewMode") private var viewMode = "Graph"
    /// Local presentation state for the non-blocking recovery overlay; never VM state.
    @State private var recoveryOverlay = WorkflowRecoveryOverlayPresentation()
    /// Focus return to the eligible badge after an explicit dismissal only (best effort).
    @FocusState private var recoveryBadgeFocused: Bool
    init(_ viewModel: VM, builderTaskView: ((String, String) -> AnyView)? = nil) {
        _viewModel = State(initialValue: viewModel)
        self.builderTaskView = builderTaskView
    }

    var body: some View {
        WorkflowScreenLayout {
            screenHeader
        } content: {
            screenContent
        }
        .background(Color.windowBG)
        .modifier(WorkflowRecoveryOverlayLifecycle(presentation: $recoveryOverlay, eligibleRunID: recoveryEligibleRunID))
        .sheet(isPresented: Binding(get: { viewModel.showsRunSheet }, set: { viewModel.showsRunSheet = $0 })) {
            WorkflowLaunchSheet(viewModel: viewModel, isGenerating: false)
        }
        .sheet(isPresented: Binding(get: { viewModel.showsGenerateSheet }, set: { viewModel.showsGenerateSheet = $0 })) {
            WorkflowLaunchSheet(viewModel: viewModel, isGenerating: true)
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .publishViewEvent(from: viewModel, to: viewEvent)
        .toolbar {
            if let error = viewModel.readFailureText {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh workflow", systemImage: "arrow.clockwise") { viewModel.retryReadFailure() }
                        .help(error)
                }
            }
        }
        .publishViewEvent(from: viewModel.parallel, to: viewEvent)
    }

    private var screenHeader: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            if viewModel.initialLoadingKind != nil {
                HStack {
                    VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                        SkeletonBlock(width: PbRadius.Metrics.workflowInspectorMinimumWidth, height: PbRadius.Metrics.spacing20)
                        SkeletonBlock(width: PbRadius.Metrics.taskSkeletonTitleWidth, height: PbRadius.Metrics.spacing14)
                    }
                    Spacer()
                }
.padding(.horizontal, PbRadius.Metrics.spacing16)
.padding(.vertical, PbRadius.Metrics.spacing12)
            } else {
                header.disabled(viewModel.initialLoadFailed).pbFadeIn()
            }
            Divider()
            if let error = viewModel.errorText, error != viewModel.readFailureText {
                Text(error)
.font(.pb(.secondary))
.foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
.frame(maxWidth: .infinity, alignment: .leading)
.padding(PbRadius.Metrics.spacing12)
                Divider()
            }
        }
    }

    @ViewBuilder private var screenContent: some View {
            if viewModel.initialLoadingKind == "run" ||
                (viewModel.initialLoadingKind == nil && !viewModel.initialLoadFailed
                    && viewModel.selectedRun != nil && viewModel.selectedRun?.isBuilder != true) {
                runContent
            } else if let loadingKind = viewModel.initialLoadingKind {
                WorkflowLoadingView(isRun: loadingKind == "run")
            } else if viewModel.initialLoadFailed {
                ContentUnavailableView("Workflow could not be loaded", systemImage: "exclamationmark.triangle")
            } else if viewModel.selectedRun?.isBuilder == true {
                builderContent.pbFadeIn()
            } else {
                editor.pbFadeIn()
            }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack(spacing: PbRadius.Metrics.spacing12) {
                VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing2) {
                    HStack(spacing: PbRadius.Metrics.spacing10) {
                    Text(viewModel.selectedRun?.name ?? (viewModel.isEditing ? (viewModel.name.isEmpty ? "New workflow" : viewModel.name) : "Workflows"))
                        .font(.pb(.title, weight: .semibold))
                    if let run = viewModel.selectedRun {
                        WorkflowRecoveryBadge(run: run, isEligible: recoveryEligibleRunID != nil,
                                              focus: $recoveryBadgeFocused, onOpen: { recoveryOverlay.openFromBadge() })
                    }
                    }
                    stateLine
                }
                Spacer()
                if viewModel.isBusy {
                    ProgressView().controlSize(.small)
                }
                headerActions
            }
            if let reason = viewModel.selectedRun?.monitorCancelRefusalReason {
                Text("Cancellation unavailable: \(reason)")
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.warningFG)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, PbRadius.Metrics.spacing16)
        .padding(.vertical, PbRadius.Metrics.spacing12)
    }

    /// The honest state line under the title. A run reports its badge state separately, so the
    /// line carries only metadata the run record already has (started time, repository) — no
    /// invented "step N of M" and no elapsed value.
    @ViewBuilder
    private var stateLine: some View {
        HStack(spacing: PbRadius.Metrics.spacing6) {
            if let run = viewModel.selectedRun {
                if let started = WorkflowRunMetadata.startedAt(run) {
                    Text("Run started \(started.formatted(date: .omitted, time: .shortened))")
                        .monospacedDigit()
                }
                if let repo = WorkflowRunMetadata.repoName(run) {
                    if WorkflowRunMetadata.startedAt(run) != nil { Text("·") }
                    Text(repo)
                        .help(run.raw["repo_path"]?.stringValue ?? repo)
                }
            } else if viewModel.isEditing {
                if viewModel.hasUnsavedChanges {
                    Circle()
                        .fill(Color.warningFG)
                        .frame(width: PbRadius.Metrics.workflowUnsavedDotSize, height: PbRadius.Metrics.workflowUnsavedDotSize)
                    Text("Unsaved changes · Revision \(viewModel.revision) · Workflow editor")
                        .monospacedDigit()
                } else {
                    Text("Revision \(viewModel.revision) · Workflow editor")
                        .monospacedDigit()
                }
            } else {
                Text("Build reusable agent workflows")
            }
        }
        .font(.pb(.secondary))
        .foregroundStyle(Color.secondaryText)
    }

    /// The header's action group: the original actions, order and guards, restyled per SPEC
    /// §5.3/§6.3 — tinted Edit with agent, an inline glass group [⋯ | Discard | Save], the
    /// primary Run, secondary glass for the run/builder actions, and the destructive Cancel run
    /// capsule. The Refresh workflow toolbar action stays separate and untouched.
    @ViewBuilder
    private var headerActions: some View {
        if let run = viewModel.selectedRun {
            if let parentID = run.parentRunID {
                Button("Open parent") { viewModel.openRun(parentID) }
                    .buttonStyle(MonitorButtonStyle(.glass))
            }
            if run.isBuilder {
                if run.status == "completed" {
                    Button(run.isBuilderProposal ? "Apply proposal" : "Open generated draft") {
                        if run.isBuilderProposal {
                            viewModel.applyAgentProposal()
                        } else {
                            viewModel.openWorkflowEditor(run.name)
                        }
                    }.buttonStyle(MonitorButtonStyle(.glass))
                }
                if viewModel.canReturnToCanvas {
                    Button("Return to canvas") { viewModel.returnToCanvas() }.buttonStyle(MonitorButtonStyle(.glass))
                }
            } else {
                Picker("View", selection: $viewMode) {
                    Text("Graph").tag("Graph")
                    Text("Parallel").tag("Parallel")
                }
                .pickerStyle(.segmented)
                .frame(width: PbRadius.Metrics.workflowRunCanvasMinimumHeight)
            }
            if run.allowsMonitorControl, ["running", "starting"].contains(run.status) {
                Button("Pause") { viewModel.control("pause") }.buttonStyle(MonitorButtonStyle(.glass))
            }
            if run.canCancelFromMonitor {
                Button("Cancel run", role: .destructive) { viewModel.control("cancel") }
                    .buttonStyle(MonitorButtonStyle(.destructive))
                    .disabled(viewModel.isBusy)
            } else if run.status == "cancelling" {
                Text("Cancelling…").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
            }
            if run.parentRunID != nil {
                Button("Open root to cancel") { viewModel.openRun(run.rootRunID) }
                    .buttonStyle(MonitorButtonStyle(.glass))
            }
        } else if viewModel.isEditing {
            Button("Edit with agent", systemImage: "sparkles") { viewModel.prepareGeneration(refining: true) }
                .buttonStyle(MonitorButtonStyle(.tinted))
                .disabled(viewModel.isBusy)
            HStack(spacing: PbRadius.Metrics.spacing2) {
                Menu {
                    Button("Generate with agent…") { viewModel.prepareGeneration(refining: false) }
                    Button("Duplicate") { viewModel.duplicate() }
                    Button("Delete", role: .destructive) { viewModel.deleteWorkflow() }.disabled(viewModel.loadedName.isEmpty)
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: PbRadius.Metrics.workflowHeaderMenuWidth,
                               height: PbRadius.Metrics.compactControlHeight)
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("More workflow actions")
                Rectangle()
                    .fill(Color.hairline)
                    .frame(width: PbRadius.Metrics.hairlineStroke,
                           height: PbRadius.Metrics.workflowHeaderDividerHeight)
                Button("Discard") { viewModel.discardChanges() }
                    .buttonStyle(QuietButtonStyle(isFilled: false))
                    .disabled(!viewModel.canDiscard)
                Button("Save") { viewModel.save() }
                    .buttonStyle(QuietButtonStyle(isFilled: false))
                    .disabled(!viewModel.canSave)
            }
            .glassEffect(.regular, in: Capsule())
            Button("Run", systemImage: "play") {
                viewModel.prepareLaunch()
            }
                .buttonStyle(MonitorButtonStyle(.primary))
                .disabled(viewModel.hasUnsavedChanges || viewModel.isBusy)
        } else {
            Button("Generate", systemImage: "sparkles") { viewModel.prepareGeneration(refining: false) }
                .buttonStyle(MonitorButtonStyle(.glass))
            Button("New workflow", systemImage: "plus") { viewModel.newWorkflow() }
                .buttonStyle(MonitorButtonStyle(.glass))
        }
    }

    private var editor: some View {
        WorkflowInspectorSplit {
            // The native adaptation of the mockup's floating overlay: the tray, the validation
            // row and the Cancel connection action sit in a measured chrome band below the
            // canvas — outside its scroll and hit-test region — over one continuous canvas
            // background, so the glass controls read as floating while covering no node, port
            // or drop target. The band reserves its own intrinsic height (it grows when the
            // chips wrap), so the canvas keeps exactly the viewport it is given; no fixed
            // overlap clearance is ever guessed.
            VStack(spacing: PbRadius.Metrics.zero) {
                // The flush-pane amendment (user override of SPEC §6.3) drops the canvas's outer
                // workflowCanvasInset: it sits edge-to-edge as before the redesign. The token
                // still pads the tray's own horizontal chrome below.
                WorkflowStandaloneBar(viewModel: viewModel)
                canvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                stepTray
                    .padding(.horizontal, PbRadius.Metrics.workflowCanvasInset)
                    .padding(.bottom, PbRadius.Metrics.spacing12)
            }
            .background(Color.inspectorFill)
        } inspector: {
            WorkflowInspector(viewModel: viewModel)
        }
    }

    private var stepTray: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack(alignment: .center, spacing: PbRadius.Metrics.spacing8) {
                Text("Add")
                    .font(.pb(.caption, weight: .semibold))
                    .foregroundStyle(Color.tertiaryText)
                    .padding(.leading, PbRadius.Metrics.spacing8)
                WorkflowStepFlowLayout(spacing: PbRadius.Metrics.spacing8) {
                    ForEach(WorkflowStepPalette.items()) { item in
                        stepItem(item)
                    }
                }
            }
            .padding(PbRadius.Metrics.workflowTrayPadding)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: PbRadius.Metrics.workflowTrayCornerRadius))
            validationRow
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Workflow steps")
    }

    /// The tray's items are drag-only: every chip keeps its existing `.draggable` payload and
    /// the already-present structural restriction (a Start/End already on the canvas is shown
    /// dimmed with its help text and cannot be dropped again). No chip gains a tap action.
    @ViewBuilder
    private func stepItem(_ item: WorkflowStepPalette.Item) -> some View {
        switch item {
        case .divider:
            Rectangle()
                .fill(Color.hairline)
                .frame(width: PbRadius.Metrics.hairlineStroke, height: PbRadius.Metrics.workflowTrayDividerHeight)
                .accessibilityHidden(true)
        case let .role(role):
            if ["start", "end"].contains(role), viewModel.nodes.contains(where: { $0.type == role }) {
                stepChip(role).opacity(0.4).help("\(WorkflowRole.title(role)) is already on the canvas")
            } else {
                stepChip(role).help("Drag \(WorkflowRole.title(role)) onto the canvas").draggable(role)
            }
        }
    }

    private var validationRow: some View { WorkflowValidationStatus(viewModel: viewModel) }

    private func stepChip(_ role: String) -> some View {
        Label(WorkflowRole.title(role), systemImage: WorkflowRole.symbol(role))
            .font(.pb(.secondary))
            .fixedSize()
            .padding(.horizontal, PbRadius.Metrics.spacing10)
            .padding(.vertical, PbRadius.Metrics.spacing6)
            .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.button))
    }

    private var canvas: some View {
        WorkflowCanvas(
            nodes: viewModel.nodes,
            edges: viewModel.edges,
            selectedNodeID: viewModel.selectedNodeID,
            selectedNodeIDs: viewModel.selectedNodeIDs,
            selectedEdgeID: viewModel.selectedEdgeID,
            isEditable: viewModel.selectedRun == nil && !viewModel.isBusy,
            takenEdgeIDs: Set(WorkflowJSON.objects(viewModel.selectedRun?.raw["decisions"]).flatMap {
                           $0["connections"]?.arrayValue?.compactMap(\.stringValue) ?? []
                       }),
            status: viewModel.nodeStatus,
            attempt: viewModel.nodeAttempt,
            onSelectNode: viewModel.selectNode,
            onSelectEdge: { viewModel.selectedEdgeID = $0; viewModel.selectedNodeID = nil },
            onMove: viewModel.moveNode,
            onSelectNodes: { viewModel.selectNodes($0, primary: $1) },
            onToggleNode: viewModel.toggleNode,
            onMoveNodes: viewModel.moveNodes,
            onBeginNodeDrag: viewModel.beginNodeDrag,
            onEndNodeDrag: viewModel.endNodeDrag,
            onConnect: { viewModel.connectionSourceID = $0 },
            onDrop: { viewModel.addNode($0, at: $1) },
            onDelete: viewModel.deleteSelected,
            onCopy: viewModel.copySelectedNodes,
            onPaste: viewModel.pasteNodes,
            canUndo: viewModel.canUndo,
            onUndo: viewModel.undoWorkflowEdit,
            onRename: { viewModel.updateNode($0, key: "title", value: .string($1)) },
            childRunID: { viewModel.selectedRun?.latestChildRunID(for: $0, selection: viewModel.branchSelection) },
            onOpenRun: viewModel.openRun,
            selectedBranchEdgeIDs: viewModel.branchSelection.selectedEdgeIDs,
            excludedBranchEdgeIDs: viewModel.branchSelection.excludedEdgeIDs,
            showsExecutionStates: viewModel.selectedRun != nil
        )
    }

    private var builderContent: some View {
        VStack(spacing: PbRadius.Metrics.zero) {
            if let run = viewModel.selectedRun, ["needs_input", "needs_attention", "failed", "paused"].contains(run.status),
               !run.reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(run.reason)
                    .font(.pb(.secondary))
                    .foregroundStyle(Color.warningFG)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PbRadius.Metrics.spacing16)
                    .padding(.vertical, PbRadius.Metrics.spacing10)
                Divider()
            }
            GeometryReader { viewport in
                let standaloneHeight = WorkflowStandaloneLayout.height
                let minimums = WorkflowBuilderLayout.minimums(height: viewport.size.height - standaloneHeight)
                WorkflowPaneViewport {
                VSplitView {
                    VStack(spacing: PbRadius.Metrics.zero) {
                        WorkflowStandaloneBar(viewModel: viewModel)
                        HSplitView {
                        canvas.frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity)
                        if viewModel.selectedNode != nil || viewModel.selectedEdge != nil
                            || viewModel.selectedOnDemandNode != nil || viewModel.isOrchestratorSelected {
                            WorkflowInspector(viewModel: viewModel)

        .frame(minWidth: PbRadius.Metrics.workflowInspectorMinimumWidth,
                idealWidth: PbRadius.Metrics.taskSkeletonStartWidth,
                maxWidth: PbRadius.Metrics.workflowInspectorMaximumWidth)
                        }
                    }
                    }
                    .frame(minWidth: PbRadius.Metrics.zero, maxWidth: .infinity,
                           minHeight: minimums.canvas + standaloneHeight,
                           idealHeight: max(standaloneHeight, viewport.size.height * 0.42))
                    .clipped()
                    GeometryReader { taskPane in
                        if let run = viewModel.selectedRun, let taskID = run.builderTaskID, let builderTaskView {
                            builderTaskView(taskID, run.id)
                                .frame(width: taskPane.size.width, height: taskPane.size.height)
                                .clipped()
                        } else {
                            HStack(spacing: PbRadius.Metrics.spacing8) {
                                ProgressView().controlSize(.small)
                                Text("Starting workflow builder…").font(.pb(.secondary)).foregroundStyle(Color.secondaryText)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }.frame(minHeight: minimums.task)
                }
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
                .clipped()
            }
        }
    }

    @ViewBuilder private var runSidebar: some View {
        if let run = viewModel.selectedRun {
            ScrollView {
            VStack(spacing: PbRadius.Metrics.zero) {
                if run.parentRunID != nil {
                    Text("Child workflow · Plan and checklist belong to this run")
.font(.pb(.caption))
.foregroundStyle(Color.tertiaryText)
        .padding(PbRadius.Metrics.spacing16)
                }
                if run.sessionOwnerRunID != run.id {
                    Button("Open owning orchestrator") { viewModel.openRun(run.sessionOwnerRunID) }
                        .buttonStyle(QuietButtonStyle())
.padding(.horizontal, PbRadius.Metrics.spacing16)
                }
                if CallerApprovalPanel.containsOptIn(.object(run.raw)) || (run.raw["approval_summary"]?["pending_count"]?.intValue ?? 0) > 0 {
                    CallerApprovalPanel(workflowRunID: run.id, polls: ["running", "needs_attention", "needs_input"].contains(run.status))
                }
                WorkflowChildLinks(groups: WorkflowChildLinkGroup.build(run: run), onOpen: viewModel.openRun)
                    .padding(.horizontal, PbRadius.Metrics.spacing16)
                    .padding(.vertical, PbRadius.Metrics.spacing4)
                if let assignment = run.raw["prompt"]?.stringValue, !assignment.isEmpty {
                    DisclosureGroup(run.parentRunID == nil ? "Original request" : "Assignment for this child") {
                        ScrollView {
                            ReadingMarkdownView(text: assignment)
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, PbRadius.Metrics.spacing6)
                                // The document probe (§6.4): inside this nested disclosure's own
                                // document, never the outer run inspector's.
                                .background(ScrollChrome())
                        }.frame(maxHeight: PbRadius.Metrics.workflowRunActivityMinimumHeight)
                    }
.font(.pb(.secondary, weight: .medium))
.padding(PbRadius.Metrics.spacing16)
                    // Native disclosure triangles extend before their label's layout origin.
                    .padding(.leading, PbRadius.Metrics.spacing8)
                }
                WorkflowGoalView(viewModel: viewModel, run: run)
                    .padding(PbRadius.Metrics.spacing16)
                    .padding(.leading, PbRadius.Metrics.spacing8)
                WorkflowRunPlan(run: run)
                    .padding(PbRadius.Metrics.spacing16)
                    .padding(.leading, PbRadius.Metrics.spacing8)
                if let plan = run.technicalPlan {
                    DisclosureGroup("Technical plan") {
                        ScrollView {
                            ReadingMarkdownView(text: plan)
.frame(maxWidth: .infinity, alignment: .leading)
.padding(.vertical, PbRadius.Metrics.spacing6)
                                // The document probe (§6.4): inside this nested disclosure's own
                                // document, never the outer run inspector's.
                                .background(ScrollChrome())
                        }.frame(maxHeight: PbRadius.Metrics.formPreviewWidth)
                    }
.font(.pb(.secondary, weight: .medium))
.padding(PbRadius.Metrics.spacing16)
                    .padding(.leading, PbRadius.Metrics.spacing8)
                }
                Divider()
                if viewModel.selectedNode != nil || viewModel.selectedEdge != nil {
                    WorkflowInspector(viewModel: viewModel, isScrollable: false)
                } else {
                    Spacer(minLength: PbRadius.Metrics.zero)
                }
            }
            // The document probe (§6.4): inside the run inspector's own document, so it can only
            // ever target this outer scroll view — never a nested disclosure's.
            .background(ScrollChrome())
            }
.accessibilityIdentifier("workflow-run-inspector")
.background(Color.cardFill)
        }
    }

    @ViewBuilder
    private var activity: some View {
        Group {
            if let node = viewModel.selectedOnDemandNode, let run = viewModel.selectedRun {
                WorkflowOnDemandCallsView(node: node, calls: run.onDemandCalls.filter { $0.nodeID == node.id }, onOpenTask: viewModel.openOwnerTask)
            } else if let native = viewModel.nativeActivity {
                WorkflowNativeActivityView(model: native)
            } else {
                WorkflowActivityColumns(
                    viewModel: viewModel.parallel,
                    selectedTaskID: selectedTaskID,
                    showsPrestartPlaceholder: WorkflowExecutionPresentation.showsPrestartPlaceholder(
                        activations: viewModel.selectedRun?.activations ?? []
                    )
                )
            }
        }
        .background(Color.cardFill)
    }

}

// MARK: - Workflow activity selection

private extension WorkflowView {
    var runContent: some View {
        let isLoading = viewModel.initialLoadingKind == "run"
        let recoveryRunID = recoveryEligibleRunID
        return GeometryReader { viewport in
            VStack(spacing: PbRadius.Metrics.zero) {
            if isLoading {
                HStack { SkeletonBlock(height: PbRadius.Metrics.spacing14); Spacer(minLength: PbRadius.Metrics.workflowLoadingSpacer) }
                    .frame(height: PbRadius.Metrics.workflowLoadingStatusHeight)
                    .padding(.horizontal, PbRadius.Metrics.spacing16)
                    .padding(.vertical, PbRadius.Metrics.spacing10)
            } else {
                WorkflowDiagnosticsViewport(maximumHeight: min(PbRadius.Metrics.workflowDiagnosticsMaximumHeight, viewport.size.height * 0.3)) {
                    WorkflowRunStatus(
                        viewModel: viewModel,
                        isRecoveryPanelVisible: recoveryOverlay.isVisible(runID: recoveryRunID)
                    )
                }
                .accessibilityIdentifier("workflow-run-diagnostics")
                .pbFadeIn()
            }
            Divider()
            WorkflowRunPanes(isGraph: viewMode == "Graph", isLoading: isLoading, canvasChromeHeight: WorkflowStandaloneLayout.height) {
                if isLoading { WorkflowLoadingCanvas() } else {
                    VStack(spacing: PbRadius.Metrics.zero) {
                        WorkflowStandaloneBar(viewModel: viewModel)
                        canvas
                    }.pbFadeIn()
                }
            } inspector: {
                if isLoading { WorkflowLoadingInspector(isRun: true) } else { runSidebar.pbFadeIn() }
            } activity: {
                if isLoading { WorkflowLoadingActivity() } else { activity.pbFadeIn() }
            }
            .overlay(alignment: .topTrailing) {
                WorkflowRecoveryOverlayHost(
                    viewModel: viewModel,
                    presentation: $recoveryOverlay,
                    onExplicitClose: { recoveryBadgeFocused = true }
                )
            }
            }
        }
    }

}
