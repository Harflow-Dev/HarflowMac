import MonitorCore
import PbUI
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
    @GestureState private var dragOrigin: CGPoint?

    private var nodeSize: CGSize { WorkflowCanvasGeometry.size(node) }
    private var canEditTitle: Bool { isEditable && ["agent", "workflow"].contains(node.type) }
    private var displayTitle: String { ["agent", "workflow"].contains(node.type) ? node.name : WorkflowRole.title(node.type) }
    private var isCompact: Bool { ["start", "end", "parallel_start", "parallel_end"].contains(node.type) }
    private var isRunning: Bool { status == "running" }
    private var outline: WorkflowNodeOutline { WorkflowNodeOutline(status: status, isSelected: isSelected) }
    private var border: Color {
        if isSelected || status == "reserved" { return .accentLink }
        return outline.isExecuting ? .accentLink.opacity(0.25) : .cardBorder
    }

    var body: some View {
        ZStack {
            card
            if node.type != "start" {
                port(isOutput: false)
                    .offset(x: -nodeSize.width / 2)
            }
            if node.type != "end" {
                port(isOutput: true)
                    .offset(x: nodeSize.width / 2)
            }
        }
        .frame(width: nodeSize.width, height: nodeSize.height)
        .opacity(status == "not_selected" ? 0.4 : 1)
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
                .overlay(Circle().stroke(isConnectionTarget && !isOutput ? Color.accentLink : Color.secondaryText, lineWidth: 1.5))
                .frame(width: isConnectionTarget && !isOutput ? 12 : 9, height: isConnectionTarget && !isOutput ? 12 : 9)
                .frame(width: 28, height: 28)
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
            VStack(spacing: 8) {
                if isRunning {
                    RunningSpinner()
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

    private var regularContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: WorkflowRole.symbol(node.type == "agent" ? node.role : node.type))
                    .foregroundStyle(Color.secondaryText)
                titleView
                Spacer(minLength: 0)
                if isRunning {
                    RunningSpinner()
                } else if status == "completed" {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.doneGreen)
                } else if ["failed", "uncertain"].contains(status) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.failedRed)
                }
            }
            HStack {
                if node.type == "agent" {
                    BackendLabel(backend: node.backend).font(.pb(.caption))
                } else {
                    Text(node.type == "workflow" ? (node.workflowName.isEmpty ? "Select workflow" : node.workflowName) : node.type.capitalized)
                        .lineLimit(1)
                        .help(node.type == "workflow" ? (node.workflowName.isEmpty ? "Select workflow" : node.workflowName) : node.type.capitalized)
                        .font(.pb(.caption))
.foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
                if attempt > 0 {
                    Text("Attempt \(attempt)").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
            }
            WorkflowNodeDetail(node: node, status: status, isEditable: isEditable, childRunID: childRunID, onOpenRun: onOpenRun)
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if canEditTitle, editedTitle != nil {
            TextField("Step title", text: Binding(get: { editedTitle ?? node.name }, set: { editedTitle = $0 }))
                .textFieldStyle(.plain)
                .multilineTextAlignment(isCompact ? .center : .leading)
                .font(.pb(.body, weight: .semibold))
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
                Text(node.name).font(.pb(.body, weight: .semibold)).lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("\(node.name)\nClick to rename this step")
            .accessibilityLabel("Edit title for \(node.name)")
        } else {
            Text(displayTitle).font(.pb(.body, weight: .semibold)).lineLimit(1).help(displayTitle)
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
        cardContent.padding(12)
        .frame(width: nodeSize.width, height: nodeSize.height)
        .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(isRunning ? Color.accentLink.opacity(0.08) : Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(border, lineWidth: outline.isEmphasized ? 2 : 1))
        .overlay {
            if outline.isExecuting {
                WorkflowRunningOutline(isSelected: isSelected)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: PbRadius.card))
        .onTapGesture {
            if editedTitle == nil { onSelect() }
        }
        .transaction { $0.animation = nil }
        .gesture(moveGesture)
    }

    private var moveGesture: some Gesture {
        DragGesture(coordinateSpace: .named("workflow-canvas"))
            .updating($dragOrigin) { _, origin, _ in
                if origin == nil { origin = node.position }
            }
            .onChanged { value in
                guard isEditable, editedTitle == nil else { return }
                let origin = dragOrigin ?? node.position
                let translation = WorkflowCanvasZoom.logical(value.translation, scale: zoom)
                onMove(CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
            }
    }
}

#if DEBUG
#Preview("Run workflow node") {
    WorkflowCanvasNode(
        node: WorkflowNodeModel(raw: ["id": .string("call"), "type": .string("workflow"), "workflow_name": .string("Review")]),
        status: "running", attempt: 1, isSelected: false, isEditable: false, zoom: 1,
        childRunID: "child", onOpenRun: { _ in }, onSelect: {}, onMove: { _ in }, onDragEnded: {}, onConnect: {},
        onRename: { _ in }, onTitleEditingChanged: { _ in }, isConnectionTarget: false,
        connectionDrag: GestureState(initialValue: nil), onDropConnectionAt: { _ in }
    ).padding(40)
}
#endif
