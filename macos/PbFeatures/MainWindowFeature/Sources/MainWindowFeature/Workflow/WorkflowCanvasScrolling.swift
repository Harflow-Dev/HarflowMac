import AppKit
import SwiftUI

// MARK: - WorkflowCanvasScrolling

enum WorkflowCanvasScrolling {
    static let edgeBand: CGFloat = 48
    static let maximumStep: CGFloat = 12

    static func step(pointer: CGPoint, viewport: CGRect) -> CGSize {
        func axis(_ position: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
            let band = min(edgeBand, (upper - lower) / 2)
            guard band > 0 else { return 0 }
            if position < lower + band { return -maximumStep * min(1, max(0, (lower + band - position) / band)) }
            if position > upper - band { return maximumStep * min(1, max(0, (position - upper + band) / band)) }
            return 0
        }
        return CGSize(width: axis(pointer.x, lower: viewport.minX, upper: viewport.maxX),
                      height: axis(pointer.y, lower: viewport.minY, upper: viewport.maxY))
    }

    static func clampedOrigin(_ origin: CGPoint, viewport: CGSize, document: CGRect) -> CGPoint {
        CGPoint(x: min(max(document.minX, origin.x), max(document.minX, document.maxX - viewport.width)),
                y: min(max(document.minY, origin.y), max(document.minY, document.maxY - viewport.height)))
    }

    static func logicalScrollDelta(before: CGRect, after: CGRect, scale: CGFloat) -> CGSize {
        WorkflowCanvasZoom.logical(CGSize(width: after.minX - before.minX, height: after.minY - before.minY), scale: scale)
    }

    static func visibleGrid(_ visible: CGRect, scale: CGFloat, content: CGSize) -> CGRect {
        let logical = CGRect(x: visible.minX / scale, y: visible.minY / scale,
                             width: visible.width / scale, height: visible.height / scale)
        return logical.insetBy(dx: -10, dy: -10).intersection(CGRect(origin: .zero, size: content))
    }
}

// MARK: - WorkflowCanvasScrollController

@Observable
@MainActor
final class WorkflowCanvasScrollController {
    private(set) var visibleRect = CGRect.zero
    private(set) var connectionDrag: WorkflowConnectionDrag?
    private(set) var isDragging = false
    @ObservationIgnored private weak var bridge: NSView?
    @ObservationIgnored private weak var scrollView: NSScrollView?
    @ObservationIgnored private var boundsObserver: NSObjectProtocol?
    @ObservationIgnored private var scrolling: Task<Void, Never>?
    @ObservationIgnored private var nodeDrag: (id: String, point: CGPoint)?
    @ObservationIgnored private var onMove: ((String, CGPoint) -> Void)?
    @ObservationIgnored private var scale: CGFloat = 1

    func attach(_ view: NSView) {
        guard let scroll = view.enclosingScrollView else { return }
        if scrollView !== scroll {
            detach()
            bridge = view
            scrollView = scroll
            scroll.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                   object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshVisibleRect() }
            }
        }
        refreshVisibleRect()
    }

    func refreshVisibleRect() {
        guard let bridge, let scrollView else { return }
        let rectangle = bridge.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        if visibleRect != rectangle { visibleRect = rectangle }
    }

    func detach() {
        stop()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        bridge = nil
        scrollView = nil
        visibleRect = .zero
    }

    func updateNode(id: String, point: CGPoint, scale: CGFloat, onMove: @escaping (String, CGPoint) -> Void) {
        nodeDrag = (id, point)
        connectionDrag = nil
        self.scale = scale
        self.onMove = onMove
        begin()
    }

    func updateConnection(_ drag: WorkflowConnectionDrag, scale: CGFloat) {
        nodeDrag = nil
        onMove = nil
        connectionDrag = drag
        self.scale = scale
        begin()
    }

    func finalConnectionPoint(fallback: CGPoint, scale: CGFloat) -> CGPoint {
        guard let bridge, let window = bridge.window else { return connectionDrag?.location ?? fallback }
        let point = bridge.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        return WorkflowCanvasZoom.logical(point, scale: scale)
    }

    func stop() {
        scrolling?.cancel()
        scrolling = nil
        nodeDrag = nil
        connectionDrag = nil
        onMove = nil
        isDragging = false
    }

    private func begin() {
        isDragging = true
        guard scrolling == nil else { return }
        scrolling = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
            }
        }
    }

    private func tick() {
        guard isDragging, let scrollView, let document = scrollView.documentView, let window = scrollView.window else { return }
        let clip = scrollView.contentView
        let pointer = clip.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let step = WorkflowCanvasScrolling.step(pointer: pointer, viewport: clip.bounds)
        let oldVisible = bridge.map { $0.convert(clip.bounds, from: clip) } ?? visibleRect
        let oldOrigin = clip.bounds.origin
        let next = WorkflowCanvasScrolling.clampedOrigin(CGPoint(x: oldOrigin.x + step.width, y: oldOrigin.y + step.height),
                                                        viewport: clip.bounds.size, document: document.bounds)
        guard next != oldOrigin else { return }
        clip.scroll(to: next)
        scrollView.reflectScrolledClipView(clip)
        refreshVisibleRect()
        let applied = WorkflowCanvasScrolling.logicalScrollDelta(before: oldVisible, after: visibleRect, scale: scale)
        if let drag = nodeDrag {
            let point = CGPoint(x: drag.point.x + applied.width, y: drag.point.y + applied.height)
            nodeDrag = (drag.id, point)
            onMove?(drag.id, point)
        }
        if let drag = connectionDrag {
            connectionDrag = WorkflowConnectionDrag(sourceID: drag.sourceID,
                                                      location: CGPoint(x: drag.location.x + applied.width, y: drag.location.y + applied.height))
        }
    }
}

// MARK: - WorkflowCanvasScrollBridge

struct WorkflowCanvasScrollBridge: NSViewRepresentable {
    let controller: WorkflowCanvasScrollController
    func makeNSView(context _: Context) -> WorkflowCanvasScrollProbe { WorkflowCanvasScrollProbe(controller: controller) }
    func updateNSView(_ view: WorkflowCanvasScrollProbe, context _: Context) { controller.attach(view) }
    static func dismantleNSView(_ view: WorkflowCanvasScrollProbe, coordinator _: Void) { view.controller?.detach() }
}

final class WorkflowCanvasScrollProbe: NSView {
    weak var controller: WorkflowCanvasScrollController?
    override var isFlipped: Bool { true }
    init(controller: WorkflowCanvasScrollController) {
        self.controller = controller
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { controller?.attach(self) }
    }

    override func layout() {
        super.layout()
        controller?.attach(self)
    }
}
