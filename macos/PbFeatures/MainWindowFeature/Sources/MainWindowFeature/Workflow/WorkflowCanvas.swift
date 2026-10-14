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
    /// A defaulted presentation input: true on a run canvas, so "pending" nodes earn the
    /// dashed 75% execution treatment instead of the editor's solid placeholder card.
    var showsExecutionStates = false
    @State private var scrollController = WorkflowCanvasScrollController()
    @State private var routeCache = WorkflowRouteCache()
    @State private var groupOrigins: [String: CGPoint] = [:]
    @State private var groupAnchor: String?
    @GestureState private var marquee: CGRect?
    @State private var marqueeBaseline: Set<String>?
    @State private var marqueeOriginal: Set<String>?
    @State private var marqueePrimary: String?
    @State private var hoveredArrow: WorkflowArrowHoverState?
    @State private var tooltipSize = CGSize(width: PbRadius.Metrics.taskSkeletonStartWidth, height: PbRadius.Metrics.workflowNodePreviewInset)
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
        let routeSnapshot = WorkflowRouteCache.snapshot(edges: edges, nodes: nodes)
        let routes = routeCache.currentRoutes(for: routeSnapshot)
        let region = parallelRegion
        let highlightedEdgeIDs = Set(edges.filter { edge in
            edge.id == selectedEdgeID || selectedBranchEdgeIDs.contains(edge.id)
                || (region.contains(edge.source) && region.contains(edge.target))
        }
.map(\.id))
        ScrollView([.horizontal, .vertical]) {
            ZStack(alignment: .topLeading) {
                Color.cardFill
.opacity(0)
                    .contentShape(Rectangle())
                    .gesture(marqueeGesture)
                    .onTapGesture { isCanvasFocused = true; onSelectNodes([], nil) }
                if let marquee {
                    Rectangle()
                .fill(Color.workflowMarqueeFill)
                        .overlay(Rectangle().stroke(Color.accentLink, lineWidth: PbRadius.Metrics.hairlineStroke))
                        .frame(width: marquee.width, height: marquee.height)
                        .position(x: marquee.midX, y: marquee.midY)
                        .allowsHitTesting(false)
                }
                ForEach(edges) { edge in
                    let highlighted = highlightedEdgeIDs.contains(edge.id)
                    edgeView(edge, points: routes[edge.id] ?? [], highlighted: highlighted)
                        .zIndex(edge.id == selectedEdgeID ? 2 : highlighted || takenEdgeIDs.contains(edge.id) ? 1 : 0)
                }
                if let drag = activeConnectionDrag, let source = nodes.first(where: { $0.id == drag.sourceID }) {
                    let target = WorkflowCanvasGeometry.target(at: drag.location, sourceID: drag.sourceID, nodes: nodes)
                    let endpoint = target.map { WorkflowCanvasGeometry.connectionInput($0, highlighted: true) } ?? drag.location
                    connectionPath(routeCache.preview(source: source, target: target, endpoint: endpoint, nodes: nodes, edges: edges))
                        .stroke(Color.accentLink, style: StrokeStyle(
                            lineWidth: PbRadius.Metrics.workflowConnectionHighlightedLineWidth,
                            dash: PbRadius.Metrics.workflowConnectionDash
                        ))
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
                        },
                        showsExecutionStates: showsExecutionStates
                    )
                        .position(WorkflowCanvasGeometry.center(node))
                }
            }
            .task(id: routeSnapshot) {
                guard !Task.isCancelled else { return }
                routeCache.request(routeSnapshot)
            }
            .frame(width: contentSize.width, height: contentSize.height)
            .scaleEffect(zoom, anchor: .topLeading)
            .frame(width: contentSize.width * zoom, height: contentSize.height * zoom, alignment: .topLeading)
            .contentShape(Rectangle())
            .coordinateSpace(name: "workflow-canvas")
            // The document probe (§6.3): inside the canvas's own document, so both of ITS axes
            // carry thin overlay chrome — never an outer lane's or the inspector's. Presentation
            // only: the controller, document size, offsets, zoom, geometry, snapping and callbacks
            // are unchanged.
            .background(ScrollChrome())
            .background(WorkflowCanvasScrollBridge(controller: scrollController))
            .onContinuousHover(coordinateSpace: .named("workflow-canvas")) { phase in
                switch phase {
                case let .active(point): updateArrowHover(at: WorkflowCanvasZoom.logical(point, scale: zoom))
                case .ended: hoveredArrow = nil
                }
            }
            .dropDestination(for: String.self) { values, location in
                guard let role = values.first, WorkflowCanvasDropPolicy.accepts(role, isEditable: isEditable, nodes: nodes) else { return false }
                onDrop(role, WorkflowCanvasZoom.logical(location, scale: zoom))
                return true
            }
        }
        .background {
            Canvas { context, _ in
                let points = WorkflowCanvasGrid.screenDots(viewport: visible, scale: zoom, content: contentSize)
                var dots = Path()
                for point in points {
                    dots.addEllipse(in: CGRect(
                        x: point.x - PbRadius.Metrics.workflowGridDotDiameter / 2,
                        y: point.y - PbRadius.Metrics.workflowGridDotDiameter / 2,
                        width: PbRadius.Metrics.workflowGridDotDiameter,
                        height: PbRadius.Metrics.workflowGridDotDiameter
                    ))
                }
                context.fill(dots, with: .color(Color.hairline))
            }.allowsHitTesting(false)
        }
        .background(Color.inspectorFill)
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
        .onChange(of: edges) { _, _ in
            hoveredArrow = nil
        }
        .onDisappear {
            onEndNodeDrag()
            hoveredArrow = nil
            scrollController.stop()
            routeCache.clear()
        }
    }

    private func connectionAt(_ point: CGPoint) -> String? {
        let routes = routeCache.currentRoutes(for: WorkflowRouteCache.snapshot(edges: edges, nodes: nodes))
        let nodeByID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let candidates = edges.compactMap { edge -> WorkflowArrowHover.Candidate? in
            guard nodeByID[edge.source] != nil, let target = nodeByID[edge.target] else { return nil }
            let finish = WorkflowCanvasGeometry.connectionInput(target)
            let points = routes[edge.id] ?? []
            return WorkflowArrowHover.Candidate(id: edge.id, path: arrowPath(points, finish: finish), points: points,
                                               hasCondition: !edge.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        return WorkflowArrowHover.nearest(to: point, candidates: candidates, preferredID: selectedEdgeID)
    }

    private func updateArrowHover(at point: CGPoint) {
        guard !scrollController.isDragging, activeConnectionDrag == nil, editingTitleNodeID == nil,
              let edgeID = connectionAt(point),
              let edge = edges.first(where: { $0.id == edgeID }),
              !edge.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { hoveredArrow = nil; return }
        hoveredArrow = WorkflowArrowHoverState(edgeID: edgeID, point: point)
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
                .foregroundStyle(Color.primaryText)
                .frame(width: min(PbRadius.Metrics.workflowTooltipMaximumWidth,
                                  max(0, viewport.width - PbRadius.Metrics.workflowTooltipHorizontalClearance)),
                       alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, PbRadius.Metrics.spacing10)
                .padding(.vertical, PbRadius.Metrics.spacing8)
                .frame(maxHeight: max(0, viewport.height - PbRadius.Metrics.workflowTooltipVerticalClearance), alignment: .topLeading)
                .fixedSize(horizontal: false, vertical: true)
                .clipped()
                .background(Color.cardFill, in: RoundedRectangle(cornerRadius: PbRadius.row))
                .overlay(RoundedRectangle(cornerRadius: PbRadius.row).stroke(Color.cardBorder))
                .background(GeometryReader { geometry in
                    Color.cardFill.opacity(0).preference(key: WorkflowTooltipSizePreference.self, value: geometry.size)
                })
                .onPreferenceChange(WorkflowTooltipSizePreference.self) { tooltipSize = $0 }
                .position(center)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private var zoomControls: some View {
        HStack(spacing: PbRadius.Metrics.spacing4) {
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: -1) } label: {
                Image(systemName: "minus")
                    .frame(width: PbRadius.Metrics.workflowZoomSymbolSize.width,
                           height: PbRadius.Metrics.workflowZoomSymbolSize.height)
            }
                .disabled(zoom <= WorkflowCanvasZoom.minimum)
                .accessibilityLabel("Zoom out")
                .help("Zoom out")
            Button { zoom = 1 } label: {
                Text("\(Int((zoom * 100).rounded()))%")
                    .font(.pb(.caption))
                    .monospacedDigit()
                    .frame(width: PbRadius.Metrics.workflowZoomResetWidth,
                           height: PbRadius.Metrics.workflowZoomSymbolSize.height)
            }
                .accessibilityLabel("Reset zoom, currently \(Int((zoom * 100).rounded())) percent")
                .help("Reset zoom to 100%")
            Button { zoom = WorkflowCanvasZoom.adjusted(zoom, steps: 1) } label: {
                Image(systemName: "plus")
                    .frame(width: PbRadius.Metrics.workflowZoomSymbolSize.width,
                           height: PbRadius.Metrics.workflowZoomSymbolSize.height)
            }
                .disabled(zoom >= WorkflowCanvasZoom.maximum)
                .accessibilityLabel("Zoom in")
                .help("Zoom in")
        }
        .buttonStyle(QuietButtonStyle())
        .disabled(scrollController.isDragging)
        .padding(PbRadius.Metrics.workflowZoomPadding)
        .glassEffect(.regular, in: Capsule())
        .padding(PbRadius.Metrics.workflowZoomInset)
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
            path.move(to: CGPoint(x: finish.x - PbRadius.Metrics.workflowArrowheadLength,
                                  y: finish.y - PbRadius.Metrics.workflowArrowheadHalfWidth))
            path.addLine(to: finish)
            path.addLine(to: CGPoint(x: finish.x - PbRadius.Metrics.workflowArrowheadLength,
                                     y: finish.y + PbRadius.Metrics.workflowArrowheadHalfWidth))
        }
    }

    /// A traversed connection is tinted doneGreen (SPEC §6.4); selection and branch paths stay
    /// accent. Stroke widths keep their existing emphasis weights.
    private func edgeColor(_ edge: WorkflowEdgeModel, highlighted: Bool) -> Color {
        if takenEdgeIDs.contains(edge.id) { return .doneGreen }
        return highlighted ? .accentLink : .tertiaryText
    }

    private func edgeWidth(_ edge: WorkflowEdgeModel, highlighted: Bool) -> CGFloat {
        (highlighted || takenEdgeIDs.contains(edge.id))
            ? PbRadius.Metrics.workflowConnectionHighlightedLineWidth
            : PbRadius.Metrics.workflowConnectionLineWidth
    }

    @ViewBuilder
    private func edgeView(_ edge: WorkflowEdgeModel, points: [CGPoint], highlighted: Bool) -> some View {
        if let source = nodes.first(where: { $0.id == edge.source }), let target = nodes.first(where: { $0.id == edge.target }) {
            let finish = WorkflowCanvasGeometry.connectionInput(target)
            let connection = arrowPath(points, finish: finish)
            let label = "Connection from \(source.name) to \(target.name)"
                + (edge.condition.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : ": \(edge.condition)")
            ZStack {
                connection.stroke(
                    edgeColor(edge, highlighted: highlighted),
                    style: StrokeStyle(
                        lineWidth: edgeWidth(edge, highlighted: highlighted),
                        dash: edge.isBackward ? PbRadius.Metrics.workflowConnectionDash : []
                    )
                )
                .opacity(excludedBranchEdgeIDs.contains(edge.id) ? 0.25
                    : !isEditable && !selectedBranchEdgeIDs.contains(edge.id) && !takenEdgeIDs.isEmpty && !takenEdgeIDs.contains(edge.id) ? 0.5 : 1)
                .contentShape(connection.strokedPath(StrokeStyle(lineWidth: PbRadius.Metrics.workflowConnectionHitWidth)))
                .onTapGesture(coordinateSpace: .named("workflow-canvas")) { location in
                    isCanvasFocused = true
                    if let edgeID = connectionAt(WorkflowCanvasZoom.logical(location, scale: zoom)) { onSelectEdge(edgeID) }
                }
                .accessibilityLabel(label)
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { isCanvasFocused = true; onSelectEdge(edge.id) }
            }
        }
    }
}

#if DEBUG
private struct WorkflowCanvasPreview: View {
    var withConditions = false
    var body: some View {
        let definition = WorkflowVM.starterDefinition()
        WorkflowCanvas(
            nodes: WorkflowJSON.nodes(definition),
            edges: WorkflowJSON.edges(definition),
            selectedNodeID: "task",
            selectedEdgeID: nil,
            isEditable: true,
            takenEdgeIDs: withConditions
                ? Set(WorkflowJSON.edges(definition).filter { !$0.condition.isEmpty }.map(\.id))
                : [],
            status: { _ in withConditions ? "completed" : "pending" },
            attempt: { _ in 0 },
            onSelectNode: { _ in },
            onSelectEdge: { _ in },
            onMove: { _, _ in },
            onConnect: { _ in },
            onDrop: { _, _ in },
            showsExecutionStates: withConditions
        )
        .frame(width: PbRadius.Metrics.toolbarPreviewWidth, height: PbRadius.Metrics.workflowCanvasPreviewHeight)
    }
}

#Preview("Workflow canvas - light") { WorkflowCanvasPreview().preferredColorScheme(.light) }
#Preview("Workflow canvas - dark") { WorkflowCanvasPreview().preferredColorScheme(.dark) }
#Preview("Workflow canvas - traversed conditions") {
    WorkflowCanvasPreview(withConditions: true).preferredColorScheme(.dark)
}
#endif
