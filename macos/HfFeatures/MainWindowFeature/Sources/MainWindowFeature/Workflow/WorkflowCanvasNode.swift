import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowCanvasNode

struct WorkflowCanvasNode: View {
    let node: WorkflowNodeModel
    let status: String
    let attempt: Int
    let isSelected: Bool
    let isEditable: Bool
    let zoom: CGFloat
    let childRunID: String?
    let onOpenRun: (String) -> Void
    let onSelect: () -> Void
    let onMove: (CGPoint) -> Void
    let onDragEnded: () -> Void
    let onConnect: () -> Void
    let onRename: (String) -> Void
    let onTitleEditingChanged: (Bool) -> Void
    @State private var editedTitle: String?
    @FocusState private var isTitleFocused: Bool
    let isConnectionTarget: Bool
    let connectionDrag: GestureState<WorkflowConnectionDrag?>
    let onDropConnectionAt: (CGPoint) -> Void
    /// True on a run canvas, where "pending" is an execution state that earns the dashed
    /// 75% treatment (SPEC §6.4). The editor's identically-named placeholder status stays a
    /// plain solid card. A defaulted presentation input; call sites without a run keep it off.
    var showsExecutionStates = false
    var standalone = false
    var standaloneSubtitle: String?
    @GestureState private var dragOrigin: CGPoint?

    private var nodeSize: CGSize { WorkflowCanvasGeometry.size(node) }
    private var canEditTitle: Bool { isEditable && ["agent", "workflow"].contains(node.type) }
    private var displayTitle: String { ["agent", "workflow"].contains(node.type) ? node.name : WorkflowRole.title(node.type) }
    private var isOrchestrator: Bool { standalone && node.id == WorkflowStandalone.orchestratorID }
    private var isCompact: Bool { ["start", "end", "parallel_start", "parallel_end"].contains(node.type) }
    private var isRunning: Bool { status == "running" }
    private var statusPresentation: StatusBadgePresentation { WorkflowNodeStatusPresentation.presentation(status: status) }
    private var isAttention: Bool { statusPresentation.tint == .warning }
    private var isFailed: Bool { statusPresentation.tint == .danger }
    /// Preserve the original rounded rectangular click and drag footprint, including capsule corners.
    static var hitShape: RoundedRectangle { RoundedRectangle(cornerRadius: HfRadius.card) }
    private var outline: WorkflowNodeOutline { WorkflowNodeOutline(status: status, isSelected: isSelected) }
    /// Start/End draw as capsules (SPEC §6.3) inside their unchanged 72 pt square footprint;
    /// every other node keeps the 12 pt card.
    private var shape: AnyShape {
        ["start", "end"].contains(node.type)
            ? AnyShape(Capsule())
            : AnyShape(RoundedRectangle(cornerRadius: HfRadius.card))
    }

    private var border: Color {
        if isSelected || status == "reserved" { return .accentLink }
        if isAttention { return .warningFG }
        if isFailed { return .failedRed }
        return outline.isExecuting ? .accentLink.opacity(0.25) : .cardBorder
    }

    private var usesDashedBorder: Bool {
        !isSelected && ((standalone && !isOrchestrator) || (showsExecutionStates && status == "pending"))
    }

    private var borderStyle: StrokeStyle {
        let width = isSelected
            ? HfRadius.Metrics.workflowNodeSelectedBorderWidth
            : (isAttention || isFailed
                ? HfRadius.Metrics.workflowNodeAttentionBorderWidth
                : (outline.isEmphasized ? HfRadius.Metrics.workflowConnectionHighlightedLineWidth : HfRadius.Metrics.hairlineStroke))
        return StrokeStyle(
            lineWidth: width,
            dash: usesDashedBorder ? HfRadius.Metrics.workflowPendingDash : []
        )
    }

    /// Only an excluded branch dims the whole node; execution pending dims its border alone.
    private var opacity: Double {
        if status == "not_selected" { return 0.4 }
        return 1
    }

    /// The selected ring (`runningBG`) and the attention ring (`warningBG`), both 4 pt and
    /// non-interactive; the running pulse stays with `WorkflowRunningOutline`.
    @ViewBuilder
    private var ringOverlay: some View {
        let ring: Color? = isSelected ? .runningBG : (isAttention ? .warningBG : (isFailed ? .dangerBG : nil))
        if let ring {
            shape
                .stroke(ring, lineWidth: HfRadius.Metrics.workflowNodeRingWidth)
                .padding(-HfRadius.Metrics.workflowNodeRingInset)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    var body: some View {
        ZStack {
            card
            if !standalone, node.type != "start" {
                port(isOutput: false)
                    .offset(x: -nodeSize.width / 2)
            }
            if !standalone, node.type != "end" {
                port(isOutput: true)
                    .offset(x: nodeSize.width / 2)
            }
        }
        .frame(width: nodeSize.width, height: nodeSize.height)
        .opacity(opacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayTitle), \(status)")
        .help(node.raw["group_label"]?.stringValue ?? displayTitle)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onSelect() }
        .onChange(of: dragOrigin) { _, origin in
            if origin == nil { onDragEnded() }
        }
    }

    private func port(isOutput: Bool) -> some View {
        Button(action: isOutput ? onConnect : onSelect) {
            Circle()
                .fill(isConnectionTarget && !isOutput ? Color.accentLink : Color.cardFill)
                .overlay(Circle().stroke(
                    isConnectionTarget && !isOutput ? Color.accentLink : Color.secondaryText,
                    lineWidth: HfRadius.Metrics.workflowConnectionLineWidth
                ))
        .frame(width: isConnectionTarget && !isOutput ? HfRadius.Metrics.spacing12 : HfRadius.Metrics.workflowPortDiameter,
                height: isConnectionTarget && !isOutput ? HfRadius.Metrics.spacing12 : HfRadius.Metrics.workflowPortDiameter)
                .frame(width: HfRadius.Metrics.spacing28, height: HfRadius.Metrics.spacing28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEditable)
        .help(isOutput ? "Drag to an input to connect, or click and select a destination" : "Input")
        .accessibilityLabel(isOutput ? "Connect from \(node.name)" : "Input to \(node.name)")
        .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("workflow-canvas"))
            .updating(connectionDrag) { value, state, _ in
                guard isEditable, isOutput else { return }
                state = WorkflowConnectionDrag(sourceID: node.id, location: WorkflowCanvasZoom.logical(value.location, scale: zoom))
            }
            .onEnded { value in
                guard isEditable, isOutput else { return }
                onDropConnectionAt(WorkflowCanvasZoom.logical(value.location, scale: zoom))
            })
    }

    @ViewBuilder
    private var cardContent: some View {
        if isCompact {
            VStack(spacing: HfRadius.Metrics.spacing8) {
                if isRunning {
                    RunningSpinner()
                } else if ["completed", "failed", "uncertain", "needs_attention", "needs_input"].contains(status),
                          case let .symbol(symbol) = statusPresentation.indicator {
                    Image(systemName: symbol).foregroundStyle(statusPresentation.tint.foreground)
                } else if node.type == "start" {
                    Image(systemName: "play.fill")
                        .foregroundStyle(Color.doneGreen)
                } else {
                    Image(systemName: WorkflowRole.symbol(node.type))
                        .foregroundStyle(isSelected ? Color.accentLink : Color.secondaryText)
                }
                titleView
            }
        } else {
            regularContent
        }
    }

    /// The 24 pt neutral role tile (SPEC §6.3): the agent's role glyph, never an agent colour.
    private var iconTile: some View {
        Image(systemName: standalone ? (isOrchestrator ? "safari" : "bolt.fill") : WorkflowRole.symbol(node.type == "agent" ? node.role : node.type))
            .font(.hf(.body))
            .foregroundStyle(isOrchestrator ? Color.white : (isSelected || isRunning ? Color.accentLink : Color.secondaryText))
            .frame(width: HfRadius.Metrics.workflowNodeIconTileSize, height: HfRadius.Metrics.workflowNodeIconTileSize)
            .background(RoundedRectangle(cornerRadius: HfRadius.Metrics.workflowNodeIconTileCornerRadius)
                .fill(isOrchestrator ? Color.accentLink : Color.neutralFill))
            .accessibilityHidden(true)
    }

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            HStack(spacing: HfRadius.Metrics.spacing8) {
                iconTile
                titleView
                if isOrchestrator {
                    Image(systemName: "lock.fill").font(.hf(.caption)).foregroundStyle(Color.tertiaryText).accessibilityLabel("Always present")
                }
                Spacer(minLength: 0)
                if isRunning {
                    RunningSpinner()
                } else if ["completed", "failed", "uncertain", "needs_attention", "needs_input"].contains(status),
                          case let .symbol(symbol) = statusPresentation.indicator {
                    Image(systemName: symbol).foregroundStyle(statusPresentation.tint.foreground)
                }
            }
            HStack(spacing: HfRadius.Metrics.spacing4) {
                if node.type == "agent" {
                    BackendLabel(backend: node.backend).font(.hf(.caption))
                    if let model = node.raw["agent"]?.objectValue?["model"]?.stringValue, !model.isEmpty {
                        Text("· \(model)")
                            .font(.hf(.caption))
                            .foregroundStyle(Color.tertiaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(-1)
                            .help(model)
                            .accessibilityLabel(model)
                    }
                } else {
                    Text(node.type == "workflow" ? (node.workflowName.isEmpty ? "Select workflow" : node.workflowName) : node.type.capitalized)
                        .lineLimit(1)
                        .help(node.type == "workflow" ? (node.workflowName.isEmpty ? "Select workflow" : node.workflowName) : node.type.capitalized)
                        .font(.hf(.caption))
.foregroundStyle(Color.tertiaryText)
                }
                Spacer(minLength: 0)
                if attempt > 0 {
                    Text("Attempt \(attempt)").font(.hf(.caption)).foregroundStyle(Color.tertiaryText).monospacedDigit()
                }
            }
            if let standaloneSubtitle {
                Text(standaloneSubtitle).font(.hf(.caption)).foregroundStyle(isRunning ? Color.accentLink : Color.secondaryText).lineLimit(1)
            } else {
                WorkflowNodeDetail(node: node, status: status, isEditable: isEditable, childRunID: childRunID, onOpenRun: onOpenRun)
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if canEditTitle, editedTitle != nil {
            TextField("Node title", text: Binding(get: { editedTitle ?? node.name }, set: { editedTitle = $0 }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(isCompact ? .center : .leading)
                .font(.hf(.body, weight: .semibold))
                .focused($isTitleFocused)
                .onSubmit { finishTitleEdit(commit: true) }
                .onExitCommand { finishTitleEdit(commit: false) }
                .onChange(of: isTitleFocused) { _, focused in
                    if !focused { finishTitleEdit(commit: true) }
                }
                .onAppear { isTitleFocused = true }
                .onDisappear { finishTitleEdit(commit: true) }
                .accessibilityLabel("Title for \(node.name)")
        } else if canEditTitle {
            Button {
                onSelect()
                guard !NSEvent.modifierFlags.contains(.command) else { return }
                editedTitle = node.name
                onTitleEditingChanged(true)
            } label: {
                Text(node.name).font(.hf(.body, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("\(node.name)\nClick to rename this node")
            .accessibilityLabel("Edit title for \(node.name)")
        } else {
            Text(displayTitle).font(.hf(.body, weight: .semibold)).lineLimit(1).help(displayTitle)
        }
    }

    private func finishTitleEdit(commit: Bool) {
        guard let draft = editedTitle else { return }
        editedTitle = nil
        isTitleFocused = false
        onTitleEditingChanged(false)
        let title = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if commit, !title.isEmpty, title != node.name { onRename(title) }
    }

    private var card: some View {
        cardContent
            .padding(HfRadius.Metrics.workflowNodePadding)
            .frame(width: nodeSize.width, height: nodeSize.height)
            .background(shape.fill(Color.cardFill))
            .overlay(shape.stroke(border, style: borderStyle)
                .opacity(showsExecutionStates && status == "pending" && !isSelected
                    ? HfRadius.Metrics.workflowNodePendingOpacity : 1))
            .overlay(ringOverlay)
            .overlay {
                if outline.isExecuting {
                    WorkflowRunningOutline(isSelected: isSelected)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            // The design's two elevation shadows (§6.3), tokenized.
            .shadow(color: Color.shadow.opacity(HfRadius.Metrics.workflowNodeShadowNearOpacity),
                    radius: HfRadius.Metrics.workflowNodeShadowNearRadius,
                    y: HfRadius.Metrics.workflowNodeShadowNearY)
            .shadow(color: Color.shadow.opacity(HfRadius.Metrics.workflowNodeShadowFarOpacity),
                    radius: HfRadius.Metrics.workflowNodeShadowFarRadius,
                    y: HfRadius.Metrics.workflowNodeShadowFarY)
            .contentShape(Self.hitShape)
            .onTapGesture {
                if editedTitle == nil { onSelect() }
            }
            .transaction { $0.animation = nil }
            .gesture(standalone ? nil : moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("workflow-canvas"))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = node.position }
            }
            .onChanged { value in
                guard isEditable, !standalone, editedTitle == nil else { return }
                let origin = dragOrigin ?? node.position
                let translation = WorkflowCanvasZoom.logical(value.translation, scale: zoom)
                onMove(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
            }
    }
}

#if DEBUG
private struct WorkflowCanvasNodePreview: View {
    var status = "running"
    var isSelected = false
    var type = "agent"
    var showsExecutionStates = false
    var standalone = false
    var standaloneSubtitle: String?
    var body: some View {
        WorkflowCanvasNode(
            node: WorkflowNodeModel(raw: [
                "id": .string("call"), "type": .string(type),
                "role": .string("implementation"), "title": .string("Implementation"),
                "agent": .object(["backend": .string("codex"), "model": .string("gpt-5")])
            ]),
            status: status, attempt: 1, isSelected: isSelected, isEditable: false, zoom: 1,
            childRunID: nil, onOpenRun: { _ in }, onSelect: {}, onMove: { _ in }, onDragEnded: {}, onConnect: {},
            onRename: { _ in }, onTitleEditingChanged: { _ in }, isConnectionTarget: false,
            connectionDrag: GestureState(initialValue: nil), onDropConnectionAt: { _ in },
            showsExecutionStates: showsExecutionStates
        )
        .padding(HfRadius.Metrics.workflowNodePreviewInset)
    }
}

#Preview("Workflow node - running, light") { WorkflowCanvasNodePreview().preferredColorScheme(.light) }
#Preview("Workflow node - selected") { WorkflowCanvasNodePreview(status: "running", isSelected: true).preferredColorScheme(.dark) }
#Preview("Workflow node - attention") { WorkflowCanvasNodePreview(status: "failed").preferredColorScheme(.light) }
#Preview("Workflow node - done") { WorkflowCanvasNodePreview(status: "completed").preferredColorScheme(.dark) }
#Preview("Workflow node - editor placeholder") { WorkflowCanvasNodePreview(status: "pending", isSelected: false).preferredColorScheme(.light) }
#Preview("Workflow node - run pending, dashed") {
    WorkflowCanvasNodePreview(status: "pending", showsExecutionStates: true).preferredColorScheme(.dark)
}

#Preview("Start and end capsules") {
    HStack(spacing: HfRadius.Metrics.workflowNodePreviewInset) {
        WorkflowCanvasNodePreview(status: "pending", type: "start")
        WorkflowCanvasNodePreview(status: "pending", type: "end")
    }
    .padding(HfRadius.Metrics.workflowNodePreviewInset)
    .preferredColorScheme(.light)
}
#endif
