import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowCanvas

struct WorkflowCanvas: View {
    let nodes: [WorkflowNodeModel]
    let edges: [WorkflowEdgeModel]
    let selectedNodeID: String?
    var selectedNodeIDs: Set<String> = []
    let selectedEdgeID: String?
    let isEditable: Bool
    var takenEdgeIDs: Set<String> = []
    let status: (String) -> String
    let attempt: (String) -> Int
    let onSelectNode: (String) -> Void
    let onSelectEdge: (String) -> Void
    let onMove: (String, CGPoint) -> Void
    var onSelectNodes: (Set<String>, String?) -> Void = { _, _ in }
    var onToggleNode: (String) -> Void = { _ in }
    var onMoveNodes: ([String: CGPoint]) -> Void = { _ in }
    let onConnect: (String) -> Void
    let onDrop: (String, CGPoint) -> Void
    var onDelete: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var onRename: (String, String) -> Void = { _, _ in }
    @State private var scrollController = WorkflowCanvasScrollController()
    @State private var routeCache = WorkflowRouteCache()
    @State private var groupOrigins: [String: CGPoint] = [:]
    @State private var groupAnchor: String?
    @GestureState private var marquee: CGRect?
    @State private var marqueeBaseline: Set<String>?
    @State private var marqueeOriginal: Set<String>?
    @State private var marqueePrimary: String?
    @State private var hoveredArrow: WorkflowArrowHoverState?
    @State private var tooltipSize = CGSize(width: 260, height: 40)
    @State private var zoom: CGFloat = 1
    @State private var editingTitleNodeID: String?
    @FocusState private var isCanvasFocused: Bool

    @GestureState private var connectionDrag: WorkflowConnectionDrag?
    private var activeConnectionDrag: WorkflowConnectionDrag? { scrollController.connectionDrag ?? connectionDrag }

    private var selection: Set<String> { selectedNodeIDs.isEmpty ? Set(selectedNodeID.map { [$0] } ?? []) : selectedNodeIDs }

    private func moveGroup(anchor id: String, point: CGPoint) {
        guard isEditable else { return }
        if groupAnchor != id {
            let ids = selection.contains(id) ? selection : [id]
            groupOrigins = Dictionary(uniqueKeysWithValues: nodes.filter { ids.contains($0.id) }.map { ($0.id, $0.position) })
            groupAnchor = id
            onSelectNodes(ids, id)
        }
        guard let origin = groupOrigins[id] else { return }
        onMoveNodes(WorkflowCanvasSelection.moved(origins: groupOrigins, delta: CGSize(width: point.x - origin.x, height: point.y - origin.y)))
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named("workflow-canvas"))
            .updating($marquee) { value, rectangle, _ in
                guard isEditable else { return }
                rectangle = WorkflowCanvasSelection.rectangle(from: WorkflowCanvasZoom.logical(value.startLocation, scale: zoom),
                                                               to: WorkflowCanvasZoom.logical(value.location, scale: zoom))
            }
            .onChanged { value in
                guard isEditable else { return }
                if marqueeBaseline == nil {
                    marqueeOriginal = selection
                    marqueePrimary = selectedNodeID
                    marqueeBaseline = NSEvent.modifierFlags.contains(.command) ? selection : []
                }
                let rectangle = WorkflowCanvasSelection.rectangle(from: WorkflowCanvasZoom.logical(value.startLocation, scale: zoom),
                                                                  to: WorkflowCanvasZoom.logical(value.location, scale: zoom))
                let hits = Set(nodes.filter { rectangle.intersects(CGRect(origin: $0.position, size: WorkflowCanvasGeometry.size($0))) }.map(\.id))
                isCanvasFocused = true
                onSelectNodes((marqueeBaseline ?? []).union(hits), nil)
            }
             .onEnded { value in
                guard isEditable else { return }
                let rectangle = WorkflowCanvasSelection.rectangle(from: WorkflowCanvasZoom.logical(value.startLocation, scale: zoom),
                                                                  to: WorkflowCanvasZoom.logical(value.location, scale: zoom))
                let hits = Set(nodes.filter { rectangle.intersects(CGRect(origin: $0.position, size: WorkflowCanvasGeometry.size($0))) }.map(\.id))
                onSelectNodes((marqueeBaseline ?? []).union(hits), nil)
                marqueeOriginal = nil
                marqueeBaseline = nil
                marqueePrimary = nil
            }
    }

    private var width: CGFloat { max(900, (nodes.map(\.position.x).max() ?? 0) + 300) }
    private var height: CGFloat { max(330, (nodes.map(\.position.y).max() ?? 0) + 180) }

    var body: some View {
        GeometryReader { viewport in
        let contentSize = WorkflowCanvasZoom.contentSize(extent: CGSize(width: width, height: height), viewport: viewport.size, scale: zoom)
        let visible = scrollController.visibleRect.isEmpty ? CGRect(origin: .zero, size: viewport.size) : scrollController.visibleRect
        let grid = WorkflowCanvasScrolling.visibleGrid(visible, scale: zoom, content: contentSize)
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.windowBG
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
                    .onTapGesture { isCanvasFocused = true; onSelectNodes([], nil) }
                if let marquee {
                    Rectangle()
.fill(Color.accentLink.opacity(0.08))
                        .overlay(Rectangle().stroke(Color.accentLink, lineWidth: 1))
                        .frame(width: marquee.width, height: marquee.height)
                        .position(x: marquee.midX, y: marquee.midY)
                        .allowsHitTesting(false)
                }
                if !grid.isNull, !grid.isEmpty {
                    Canvas { context, size in
                        let first = WorkflowCanvasScrolling.firstLocalGridDot(in: grid)
                        var dots = Path()
                        for x in stride(from: first.x, through: size.width, by: WorkflowCanvasGeometry.gridSpacing) {
                            for y in stride(from: first.y, through: size.height, by: WorkflowCanvasGeometry.gridSpacing) {
                                dots.addEllipse(in: CGRect(x: x - 0.5, y: y - 0.5, width: 1, height: 1))
                            }
                        }
                        context.fill(dots, with: .color(Color.secondaryText.opacity(0.10)))
                    }
                    .frame(width: grid.width, height: grid.height)
                    .position(x: grid.midX, y: grid.midY)
                    .allowsHitTesting(false)
                }
                ForEach(edges) { edge in edgeView(edge) }
                if let drag = activeConnectionDrag, let source = nodes.first(where: { $0.id == drag.sourceID }) {
                    let target = WorkflowCanvasGeometry.target(at: drag.location, sourceID: drag.sourceID, nodes: nodes)
                    let endpoint = target.map { WorkflowCanvasGeometry.connectionInput($0, highlighted: true) } ?? drag.location
                    connectionPath(routeCache.route(id: "preview", source: source, target: target, endpoint: endpoint, nodes: nodes))
                        .stroke(Color.accentLink, style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                        .allowsHitTesting(false)
                }
                ForEach(nodes) { node in
                    WorkflowCanvasNode(
                        node: node,
                        status: status(node.id),
                        attempt: attempt(node.id),
                        isSelected: selection.contains(node.id),
                        isEditable: isEditable,
                        zoom: zoom,
                        onSelect: { isCanvasFocused = true; if NSEvent.modifierFlags.contains(.command) { onToggleNode(node.id) } else { onSelectNode(node.id) } },
                        onMove: { point in
                            moveGroup(anchor: node.id, point: point)
                            scrollController.updateNode(id: node.id, point: point, scale: zoom, onMove: moveGroup)
                        },
                        onDragEnded: { scrollController.stop(); groupOrigins = [:]; groupAnchor = nil },
                        onConnect: { isCanvasFocused = true; onConnect(node.id) },
                        onRename: { onRename(node.id, $0) },
                        onTitleEditingChanged: { editing in
                            if editing {
                                editingTitleNodeID = node.id
                                isCanvasFocused = false
                            } else if editingTitleNodeID == node.id {
                                editingTitleNodeID = nil
                            }
                        },
                        isConnectionTarget: isConnectionTarget(node),
                        connectionDrag: $connectionDrag,
                        onDropConnectionAt: { location in
                            let location = scrollController.finalConnectionPoint(fallback: location, scale: zoom)
                            guard let target = WorkflowCanvasGeometry.target(at: location, sourceID: node.id, nodes: nodes) else { return }
                            isCanvasFocused = true
                            onConnect(node.id)
                            onSelectNode(target.id)
                        }
                    )
                        .position(WorkflowCanvasGeometry.center(node))
                }
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: "workflow-canvas")
            .background(WorkflowCanvasScrollBridge(controller: scrollController))
            .onContinuousHover(coordinateSpace: .named("workflow-canvas")) { phase in
                switch phase {
                case let .active(point): updateArrowHover(at: WorkflowCanvasZoom.logical(point, scale: zoom))
                case .ended: hoveredArrow = nil
                }
            }
            .dropDestination(for: String.self) { values, location in
                guard isEditable, let role = values.first,
                      ["planning", "implementation", "review", "task", "start", "join", "end"].contains(role) else {
                          return false
                      }
                guard !["start", "end"].contains(role) || !nodes.contains(where: { $0.type == role }) else { return false }
                onDrop(role, WorkflowCanvasZoom.logical(location, scale: zoom))
                return true
            }
        }
        .background(Color.windowBG)
        .focusable(isEditable)
        .focusEffectDisabled()
        .focused($isCanvasFocused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard isEditable, editingTitleNodeID == nil, selectedNodeID != nil || selectedEdgeID != nil else { return .ignored }
            onDelete()
            return .handled
        }
        .modifier(WorkflowClipboardCommands(isEnabled: isCanvasFocused && isEditable && editingTitleNodeID == nil, onCopy: onCopy, onPaste: onPaste))
        .onDeleteCommand {
            guard isCanvasFocused, isEditable, editingTitleNodeID == nil, selectedNodeID != nil || selectedEdgeID != nil else { return }
            onDelete()
        }
        .accessibilityLabel("Workflow graph")
        .overlay(alignment: .topLeading) { arrowTooltip(viewport: viewport.size) }
        }
        .overlay(alignment: .bottomTrailing) { zoomControls }
        .onChange(of: connectionDrag) { _, drag in
            if let drag { scrollController.updateConnection(drag, scale: zoom) } else { scrollController.stop() }
        }
        .onChange(of: marquee) { _, rectangle in if rectangle == nil {
                if let original = marqueeOriginal { onSelectNodes(original, marqueePrimary) }
                marqueeOriginal = nil
                marqueeBaseline = nil
                marqueePrimary = nil
            } }
        .onChange(of: isEditable) { _, _ in scrollController.stop(); groupOrigins = [:]; groupAnchor = nil; hoveredArrow = nil }
        .onChange(of: zoom) { _, _ in scrollController.stop(); groupOrigins = [:]; groupAnchor = nil; hoveredArrow = nil }
        .onChange(of: scrollController.visibleRect) { _, _ in hoveredArrow = nil }
        .onChange(of: scrollController.isDragging) { _, dragging in if dragging { hoveredArrow = nil } }
        .onChange(of: nodes) { _, _ in hoveredArrow = nil }
        .onChange(of: editingTitleNodeID) { _, _ in hoveredArrow = nil }
        .onAppear { routeCache.retain(ids: Set(edges.map(\.id)).union(["preview"])) }
        .onChange(of: edges) { _, edges in
            hoveredArrow = nil
            routeCache.retain(ids: Set(edges.map(\.id)).union(["preview"]))
        }
        .onDisappear {
            hoveredArrow = nil
            scrollController.stop()
            routeCache.retain(ids: [])
        }
    }

    private func updateArrowHover(at point: CGPoint) {
        guard !scrollController.isDragging, activeConnectionDrag == nil, editingTitleNodeID == nil else { hoveredArrow = nil; return }
        let candidates = edges.compactMap { edge -> WorkflowArrowHover.Candidate? in
            guard !edge.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let source = nodes.first(where: { $0.id == edge.source }), let target = nodes.first(where: { $0.id == edge.target }) else { return nil }
            let finish = WorkflowCanvasGeometry.connectionInput(target)
            let points = routeCache.route(id: edge.id, source: source, target: target, endpoint: finish, nodes: nodes)
            return WorkflowArrowHover.Candidate(id: edge.id, path: arrowPath(points, finish: finish), points: points)
        }
        hoveredArrow = WorkflowArrowHover.nearest(to: point, candidates: candidates).map { WorkflowArrowHoverState(edgeID: $0, point: point) }
    }

    @ViewBuilder
    private func arrowTooltip(viewport: CGSize) -> some View {
        if let hoveredArrow, !scrollController.isDragging, activeConnectionDrag == nil,
           let edge = edges.first(where: { $0.id == hoveredArrow.edgeID }), !edge.condition.isEmpty {
            let cursor = WorkflowArrowHover.viewportPoint(logical: hoveredArrow.point, scale: zoom,
                                                         visibleOrigin: scrollController.visibleRect.origin)
            let center = WorkflowArrowHover.tooltipCenter(cursor: cursor, size: tooltipSize, viewport: viewport)
            Text(edge.condition)
                .font(.pb(.caption))
                .foregroundStyle(.primary)
                .frame(width: min(240, max(0, viewport.width - 36)), alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxHeight: max(0, viewport.height - 16), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: WorkflowTooltipSizePreference.self, value: geometry.size)
                })
                .onPreferenceChange(WorkflowTooltipSizePreference.self) { tooltipSize = $0 }
                .position(center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: 4) {
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: -1) } label: { Image(systemName: "minus") }
                .disabled(zoom <= WorkflowCanvasZoom.minimum)
                .accessibilityLabel("Zoom out")
                .help("Zoom out")
            Button("\(Int((zoom * 100).rounded()))%") { zoom = 1 }
                .font(.pb(.caption))
                .monospacedDigit()
                .frame(minWidth: 44)
                .accessibilityLabel("Reset zoom, currently \(Int((zoom * 100).rounded())) percent")
                .help("Reset zoom to 100%")
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: 1) } label: { Image(systemName: "plus") }
                .disabled(zoom >= WorkflowCanvasZoom.maximum)
                .accessibilityLabel("Zoom in")
                .help("Zoom in")
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(scrollController.isDragging)
        .padding(6)
        .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
        .padding(12)
    }

    private func isConnectionTarget(_ node: WorkflowNodeModel) -> Bool {
        guard let drag = activeConnectionDrag else { return false }
        return WorkflowCanvasGeometry.target(at: drag.location, sourceID: drag.sourceID, nodes: nodes)?.id == node.id
    }

    private func connectionPath(_ points: [CGPoint]) -> Path {
        Path { path in
            guard let first = points.first else { return }
            path.move(to: first)
            for index in points.indices.dropFirst().dropLast() {
                let previous = points[index - 1]
                let corner = points[index]
                let next = points[index + 1]
                let incoming = hypot(corner.x - previous.x, corner.y - previous.y)
                let outgoing = hypot(next.x - corner.x, next.y - corner.y)
                guard incoming > 0, outgoing > 0 else { continue }
                let radius = min(10, incoming / 2, outgoing / 2)
                let entry = CGPoint(x: corner.x + (previous.x - corner.x) * radius / incoming,
                                    y: corner.y + (previous.y - corner.y) * radius / incoming)
                let exit = CGPoint(x: corner.x + (next.x - corner.x) * radius / outgoing,
                                   y: corner.y + (next.y - corner.y) * radius / outgoing)
                path.addLine(to: entry)
                path.addQuadCurve(to: exit, control: corner)
            }
            if let last = points.last { path.addLine(to: last) }
        }
    }

    private func arrowPath(_ points: [CGPoint], finish: CGPoint) -> Path {
        Path { path in
            path.addPath(connectionPath(points))
            path.move(to: CGPoint(x: finish.x - 7, y: finish.y - 5))
            path.addLine(to: finish)
            path.addLine(to: CGPoint(x: finish.x - 7, y: finish.y + 5))
        }
    }

    @ViewBuilder
    private func edgeView(_ edge: WorkflowEdgeModel) -> some View {
        if let source = nodes.first(where: { $0.id == edge.source }), let target = nodes.first(where: { $0.id == edge.target }) {
            let finish = WorkflowCanvasGeometry.connectionInput(target, highlighted: isConnectionTarget(target))
            let points = routeCache.route(id: edge.id, source: source, target: target, endpoint: finish, nodes: nodes)
            let connection = arrowPath(points, finish: finish)
            let label = "Connection from \(source.name) to \(target.name)"
                + (edge.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ": \(edge.condition)")
            connection.stroke(
                edge.id == selectedEdgeID || takenEdgeIDs.contains(edge.id) ? Color.accentLink : Color.secondaryText.opacity(0.7),
                style: StrokeStyle(
                    lineWidth: edge.id == selectedEdgeID || takenEdgeIDs.contains(edge.id) ? 2 : 1.5,
                    dash: edge.isBackward ? [5, 3] : []
                )
            )
            .opacity(!isEditable && !takenEdgeIDs.isEmpty && !takenEdgeIDs.contains(edge.id) ? 0.5 : 1)
            .contentShape(connection.strokedPath(StrokeStyle(lineWidth: 18)))
            .onTapGesture { isCanvasFocused = true; onSelectEdge(edge.id) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isCanvasFocused = true; onSelectEdge(edge.id) }
        }
    }
}

// MARK: - WorkflowCanvasNode

private struct WorkflowCanvasNode: View {
    let node: WorkflowNodeModel
    let status: String
    let attempt: Int
    let isSelected: Bool
    let isEditable: Bool
    let zoom: CGFloat
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
    private var canEditTitle: Bool { isEditable && node.type == "agent" }
    private var displayTitle: String { node.type == "agent" ? node.name : WorkflowRole.title(node.type) }
    private var isCompact: Bool { ["start", "end"].contains(node.type) }
    private var isRunning: Bool { ["running", "reserved"].contains(status) }
    private var border: Color { isRunning || isSelected ? .accentLink : .cardBorder }

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
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(displayTitle), \(status)")
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
                    Text(node.type.capitalized).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
                Spacer(minLength: 0)
                if attempt > 0 {
                    Text("Attempt \(attempt)").font(.pb(.caption)).foregroundStyle(Color.secondaryText)
                }
            }
            WorkflowNodeDetail(node: node, status: status, isEditable: isEditable)
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
            .help("Click to rename this step")
            .accessibilityLabel("Edit title for \(node.name)")
        } else {
            Text(displayTitle).font(.pb(.body, weight: .semibold)).lineLimit(1)
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
        .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(border, lineWidth: isRunning || isSelected ? 2 : 1))
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

// MARK: - WorkflowRole

enum WorkflowRole {
    static let palette = ["start", "planning", "implementation", "review", "task", "end"]
    static func title(_ role: String) -> String { role == "join" ? "Wait for all" : role.capitalized }
    static func symbol(_ role: String) -> String {
        switch role {
        case "planning": "list.bullet.clipboard"
        case "implementation": "hammer"
        case "review": "checkmark.bubble"
        case "task": "terminal"
        case "start": "play"
        case "join": "arrow.triangle.merge"
        case "end": "stop"
        default: "circle"
        }
    }
}

#if DEBUG
#Preview {
    let definition = WorkflowVM.starterDefinition()
    WorkflowCanvas(
        nodes: WorkflowJSON.nodes(definition),
        edges: WorkflowJSON.edges(definition),
        selectedNodeID: "task",
        selectedEdgeID: nil,
        isEditable: true,
        status: { _ in "pending" },
        attempt: { _ in 0 },
        onSelectNode: { _ in },
        onSelectEdge: { _ in },
        onMove: { _, _ in },
        onConnect: { _ in },
        onDrop: { _, _ in }
    )
        .frame(width: 900, height: 360)
}
#endif
