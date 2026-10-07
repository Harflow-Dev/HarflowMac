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
    var onBeginNodeDrag: () -> Void = {}
    var onEndNodeDrag: () -> Void = {}
    let onConnect: (String) -> Void
    let onDrop: (String, CGPoint) -> Void
    var onDelete: () -> Void = {}
    var onCopy: () -> Void = {}
    var onPaste: () -> Void = {}
    var canUndo = false
    var onUndo: () -> Void = {}
    var onRename: (String, String) -> Void = { _, _ in }
    var childRunID: (String) -> String? = { _ in nil }
    var onOpenRun: (String) -> Void = { _ in }
    var selectedBranchEdgeIDs: Set<String> = []
    var excludedBranchEdgeIDs: Set<String> = []
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
    @FocusState var isCanvasFocused: Bool

    @GestureState private var connectionDrag: WorkflowConnectionDrag?
    private var activeConnectionDrag: WorkflowConnectionDrag? { scrollController.connectionDrag ?? connectionDrag }

    private var parallelRegion: Set<String> {
        guard let selectedNodeID, let node = nodes.first(where: { $0.id == selectedNodeID }), node.isParallelBoundary else { return [] }
        return WorkflowParallelGroup.region(of: node, nodes: nodes, edges: edges)
    }

    private var selection: Set<String> { selectedNodeIDs.isEmpty ? Set(selectedNodeID.map { [$0] } ?? []) : selectedNodeIDs }

    private func moveGroup(anchor id: String, point: CGPoint) {
        guard isEditable else { return }
        if groupAnchor != id {
            isCanvasFocused = true
            onBeginNodeDrag()
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
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.clear
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
                        isSelected: selection.contains(node.id) || parallelRegion.contains(node.id),
                        isEditable: isEditable,
                        zoom: zoom,
                        childRunID: childRunID(node.id),
                        onOpenRun: onOpenRun,
                        onSelect: { isCanvasFocused = true; if NSEvent.modifierFlags.contains(.command) { onToggleNode(node.id) } else { onSelectNode(node.id) } },
                        onMove: { point in
                            moveGroup(anchor: node.id, point: point)
                            scrollController.updateNode(id: node.id, point: point, scale: zoom, onMove: moveGroup)
                        },
                        onDragEnded: { scrollController.stop(); onEndNodeDrag(); groupOrigins = [:]; groupAnchor = nil },
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
                      ["planning", "implementation", "review", "task", "start", "join", "end", "parallel_group"].contains(role) else {
                          return false
                      }
                guard !["start", "end"].contains(role) || !nodes.contains(where: { $0.type == role }) else { return false }
                onDrop(role, WorkflowCanvasZoom.logical(location, scale: zoom))
                return true
            }
        }
        .background {
            Canvas { context, _ in
                let points = WorkflowCanvasGrid.screenDots(viewport: visible, scale: zoom, content: contentSize)
                var dots = Path()
                for point in points {
                    dots.addEllipse(in: CGRect(x: point.x - 0.85, y: point.y - 0.85, width: 1.7, height: 1.7))
                }
                context.fill(dots, with: .color(Color.secondaryText.opacity(0.30)))
            }.allowsHitTesting(false)
        }
        .background(Color.windowBG)
        .focusable(isEditable)
        .focusEffectDisabled()
        .focused($isCanvasFocused)
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard isEditable, editingTitleNodeID == nil, selectedNodeID != nil || selectedEdgeID != nil else { return .ignored }
            deletePreservingCanvasFocus()
            return .handled
        }
        .modifier(WorkflowClipboardCommands(isEnabled: isCanvasFocused && isEditable && editingTitleNodeID == nil, onCopy: onCopy, onPaste: onPaste))
        .modifier(WorkflowUndoCommands(isEnabled: isCanvasFocused && isEditable && editingTitleNodeID == nil && canUndo, onUndo: onUndo))
        .onDeleteCommand {
            guard isCanvasFocused, isEditable, editingTitleNodeID == nil, selectedNodeID != nil || selectedEdgeID != nil else { return }
            deletePreservingCanvasFocus()
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
        .onChange(of: isEditable) { _, _ in scrollController.stop(); onEndNodeDrag(); groupOrigins = [:]; groupAnchor = nil; hoveredArrow = nil }
        .onChange(of: zoom) { _, _ in scrollController.stop(); onEndNodeDrag(); groupOrigins = [:]; groupAnchor = nil; hoveredArrow = nil }
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
            onEndNodeDrag()
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
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: -1) } label: { Image(systemName: "minus").frame(width: 14, height: 18) }
                .disabled(zoom <= WorkflowCanvasZoom.minimum)
                .accessibilityLabel("Zoom out")
                .help("Zoom out")
            Button { zoom = 1 } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.pb(.caption))
                    .monospacedDigit()
                    .frame(width: 44, height: 18)
            }
                .accessibilityLabel("Reset zoom, currently \(Int((zoom * 100).rounded())) percent")
                .help("Reset zoom to 100%")
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: 1) } label: { Image(systemName: "plus").frame(width: 14, height: 18) }
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

    private func isHighlighted(_ edge: WorkflowEdgeModel) -> Bool {
        edge.id == selectedEdgeID || selectedBranchEdgeIDs.contains(edge.id) || takenEdgeIDs.contains(edge.id)
            || (parallelRegion.contains(edge.source) && parallelRegion.contains(edge.target))
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
                isHighlighted(edge) ? Color.accentLink : Color.secondaryText.opacity(0.7),
                style: StrokeStyle(
                    lineWidth: isHighlighted(edge) ? 2 : 1.5,
                    dash: edge.isBackward ? [5, 3] : []
                )
            )
            .opacity(excludedBranchEdgeIDs.contains(edge.id) ? 0.25
                : !isEditable && !selectedBranchEdgeIDs.contains(edge.id) && !takenEdgeIDs.isEmpty && !takenEdgeIDs.contains(edge.id) ? 0.5 : 1)
            .contentShape(connection.strokedPath(StrokeStyle(lineWidth: 18)))
            .onTapGesture { isCanvasFocused = true; onSelectEdge(edge.id) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { isCanvasFocused = true; onSelectEdge(edge.id) }
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
