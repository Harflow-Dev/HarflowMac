import AppKit
import Combine
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnUIState

/// Lightweight interaction state survives eviction of a conversation's activity view.
@Observable
@MainActor
final class ParallelColumnUIState {
    var expandedGroups: Set<String> = []
    @ObservationIgnored private var followState = FollowLiveScrollState()
    private var followsLive = true
    var followLive: FollowLiveScrollState {
        get { _ = followsLive; return followState }
        set {
            followState = newValue
            if followsLive != newValue.isFollowing { followsLive = newValue.isFollowing }
        }
    }

    var retainedFirstID: String?
    var recentFirstID: String?
    @ObservationIgnored var anchor: ParallelVerticalAnchor?
    @ObservationIgnored var scrollOffset: CGFloat = 0
    @ObservationIgnored var viewportPositioned = false
    @ObservationIgnored var activityMembers: Set<String> = []
    @ObservationIgnored var oldestSequences: [String: Int] = [:]
    @ObservationIgnored var paginationRevision = 0
    @ObservationIgnored var inventoryMembers: [String: TaskInfo] = [:]
    @ObservationIgnored var inventorySession: String?
    @ObservationIgnored var inventoryCursor: String?
    @ObservationIgnored var inventoryComplete = false
}

// MARK: - ParallelVerticalAnchor

struct ParallelVerticalAnchor: Equatable {
    let id: String
    let index: Int
    let relativeOffset: CGFloat

    static func capture(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat = 0) -> Self? {
        var lower = 0
        var upper = ids.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            guard let frame = frames[ids[middle]] else {
                return captureMeasured(ids: ids, frames: frames, viewportHeight: viewportHeight, offset: offset)
            }
            if frame.maxY <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < ids.count, let frame = frames[ids[lower]],
              frame.minY < offset + viewportHeight else { return nil }
        return Self(id: ids[lower], index: lower, relativeOffset: frame.minY - offset)
    }

    private static func captureMeasured(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat) -> Self? {
        let visible = frames.filter { $0.value.maxY > offset && $0.value.minY < offset + viewportHeight }
        guard let first = visible.min(by: { $0.value.minY < $1.value.minY }),
              let index = ids.firstIndex(of: first.key) else { return nil }
        return Self(id: first.key, index: index, relativeOffset: first.value.minY - offset)
    }

    func offset(in frame: CGRect) -> CGFloat {
        // Reflow can shorten a row past its saved intra-row reading position.
        // Keep that row visible rather than restoring an offset inside its successor.
        max(0, frame.minY - max(relativeOffset, -max(0, frame.height - 1)))
    }

    func resolvedID(in ids: [String]) -> String? {
        if ids.contains(id) { return id }
        guard !ids.isEmpty else { return nil }
        return ids[min(index, ids.count - 1)]
    }
}

// MARK: - ParallelHorizontalAnchor

struct ParallelHorizontalAnchor: Equatable {
    let id: String
    let index: Int
    let relativeOffset: CGFloat
    let previousIDs: [String]

    static func capture(ids: [String], stride: CGFloat, offset: CGFloat) -> Self? {
        guard !ids.isEmpty, stride > 0 else { return nil }
        let index = min(ids.count - 1, max(0, Int(floor(max(0, offset) / stride))))
        return Self(id: ids[index], index: index, relativeOffset: offset - CGFloat(index) * stride, previousIDs: ids)
    }

    func offset(ids: [String], stride: CGFloat) -> CGFloat {
        guard !ids.isEmpty else { return 0 }
        let positions = Dictionary(ids.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var position = positions[id]
        if position == nil {
            for distance in 1 ... max(1, previousIDs.count) {
                let next = index + distance
                let previous = index - distance
                if next < previousIDs.count, let survivor = positions[previousIDs[next]] { position = survivor; break }
                if previous >= 0, let survivor = positions[previousIDs[previous]] { position = survivor; break }
            }
        }
        return CGFloat(position ?? min(index, ids.count - 1)) * stride + min(relativeOffset, max(0, stride - 1))
    }
}

// MARK: - ParallelScrollObserver

/// Native observation also covers scrollbar and keyboard movement on macOS 14.
struct ParallelScrollObserver: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var columnIDs: [String] = []
    var columnStride: CGFloat = 0
    var restorationOffset: CGFloat?
    var restorationActive = false
    var onViewportSize: ((CGSize) -> Void)?
    var onUpwardIntent: (() -> Void)?
    let onPosition: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: ParallelScrollObservationView, coordinator: ()) {
        view.removeWheelMonitor()
    }

    func updateNSView(_ view: ParallelScrollObservationView, context: Context) {
        view.axis = axis
        view.onPosition = onPosition
        view.onViewportSize = onViewportSize
        view.onUpwardIntent = onUpwardIntent
        view.updateWheelMonitor()
        view.configure(ids: columnIDs, stride: columnStride, restorationOffset: restorationOffset, restorationActive: restorationActive)
    }
}

// MARK: - ParallelScrollObservationView

final class ParallelScrollObservationView: NSView {
    var axis = ParallelScrollObserver.Axis.horizontal
    var onPosition: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onViewportSize: ((CGSize) -> Void)?
    var onUpwardIntent: (() -> Void)?
    private var wheelMonitor: Any?
    private weak var observedScrollView: NSScrollView?
    private var subscriptions = Set<AnyCancellable>()
    private var ids: [String] = []
    private var stride: CGFloat = 0
    private var pendingOffset: CGFloat?
    private var applyingRestoration = false
    private var requestedOffset: CGFloat?
    private var restorationActive = false
    private var configuredAxis: ParallelScrollObserver.Axis?
    private var pendingPositionAcknowledgement = false
    private var lastOffset: CGFloat = 0
    private var lastReported: CGRect?
    private var lastViewportSize: CGSize?

    func configure(ids: [String], stride: CGFloat, restorationOffset: CGFloat?, restorationActive: Bool) {
        let geometryChanged = configuredAxis != axis || ids != self.ids || stride != self.stride
        guard geometryChanged || restorationOffset != requestedOffset || restorationActive != self.restorationActive else { return }
        if !restorationActive { pendingPositionAcknowledgement = false }
        if restorationActive, restorationOffset != nil,
           restorationOffset != requestedOffset || restorationActive != self.restorationActive {
            pendingPositionAcknowledgement = true
        }
        configuredAxis = axis
        self.restorationActive = restorationActive
        if axis == .horizontal, ids != self.ids || stride != self.stride,
           let anchor = ParallelHorizontalAnchor.capture(ids: self.ids, stride: self.stride, offset: lastOffset) {
            pendingOffset = anchor.offset(ids: ids, stride: stride)
        }
        self.ids = ids
        self.stride = stride
        if restorationOffset != requestedOffset {
            requestedOffset = restorationOffset
            if let restorationOffset { pendingOffset = restorationOffset } else if axis == .vertical { pendingOffset = nil }
        }
        DispatchQueue.main.async { [weak self] in self?.attach(); self?.report() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            subscriptions.removeAll()
            removeWheelMonitor()
            observedScrollView = nil
            lastReported = nil
            lastViewportSize = nil
        } else { DispatchQueue.main.async { [weak self] in self?.attach() } }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.attach() }
    }

    private func attach() {
        guard window != nil, let scroll = enclosingScrollView, scroll !== observedScrollView,
              let document = scroll.documentView else { return }
        subscriptions.removeAll()
        removeWheelMonitor()
        observedScrollView = scroll
        updateWheelMonitor()
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        document.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, document)
        ] {
            NotificationCenter.default
                .publisher(for: name, object: object)
                .sink { [weak self] _ in self?.report(observeExternalMovement: name == NSView.boundsDidChangeNotification) }
                .store(in: &subscriptions)
        }
        report()
    }

    func updateWheelMonitor() {
        guard onUpwardIntent != nil, observedScrollView?.window != nil else {
            removeWheelMonitor()
            return
        }
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.observeWheelIntent(event)
            return event
        }
    }

    func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    private func observeWheelIntent(_ event: NSEvent) {
        guard axis == .vertical, let scroll = observedScrollView, event.window === scroll.window,
              scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
              event.scrollingDeltaY > 0, event.momentumPhase.isEmpty,
              event.phase.isEmpty || event.phase.contains(.began) else { return }
        onUpwardIntent?()
    }

    /// Observe an upward reading move before a queued layout restoration can replace it.
    /// Content shrinkage and viewport resizing remain layout changes, not user scroll evidence.
    private func observeExternalUpwardScroll(visible: CGRect, document: NSView, length: CGFloat, viewport: CGFloat) {
        let offset = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
        guard axis == .vertical, let lastReported, offset < lastOffset - 0.5,
              abs(length - lastReported.width) < 0.5, viewport == lastReported.height else { return }
        pendingOffset = nil
        requestedOffset = nil
        lastOffset = offset
        self.lastReported = CGRect(x: offset, y: 0, width: length, height: viewport)
        onPosition?(offset, length, viewport)
    }

    private func report(observeExternalMovement: Bool = false) {
        guard let scroll = observedScrollView, let document = scroll.documentView else { return }
        let visible = scroll.documentVisibleRect
        let viewportSize = scroll.contentView.bounds.size
        if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            onViewportSize?(viewportSize)
        }
        let length = axis == .horizontal ? document.bounds.width : document.bounds.height
        let viewport = axis == .horizontal ? viewportSize.width : viewportSize.height
        if observeExternalMovement, !applyingRestoration {
            observeExternalUpwardScroll(visible: visible, document: document, length: length, viewport: viewport)
        }
        let horizontalLayoutReady = axis != .horizontal || abs(length - CGFloat(ids.count) * stride) < 2
        if restorationActive, pendingOffset == nil, let requestedOffset { pendingOffset = requestedOffset }
        if let pendingOffset, viewport > 0, horizontalLayoutReady {
            self.pendingOffset = nil
            let target = min(max(0, pendingOffset), max(0, length - viewport))
            var point = scroll.contentView.bounds.origin
            if axis == .horizontal { point.x = target } else { point.y = document.isFlipped ? target : max(0, document.bounds.maxY - viewport - target) }
            if abs((axis == .horizontal ? point.x : point.y) - (axis == .horizontal ? visible.minX : visible.minY)) > 0.5 {
                applyingRestoration = true
                scroll.contentView.scroll(to: point)
                scroll.reflectScrolledClipView(scroll.contentView)
                applyingRestoration = false
            }
        }
        let updated = scroll.documentVisibleRect
        lastOffset = axis == .horizontal ? updated.minX : (document.isFlipped ? updated.minY : document.bounds.maxY - updated.maxY)
        let report = CGRect(x: lastOffset, y: 0, width: length, height: viewport)
        let acknowledgesRestoration = pendingPositionAcknowledgement && viewport > 0 && horizontalLayoutReady && pendingOffset == nil
        if acknowledgesRestoration { pendingPositionAcknowledgement = false }
        if report != lastReported || acknowledgesRestoration {
            lastReported = report
            onPosition?(lastOffset, length, viewport)
        }
    }
}
