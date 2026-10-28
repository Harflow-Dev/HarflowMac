import AppKit
import Combine
import MonitorCore
import SwiftUI

// MARK: - ParallelScrollObservationView

final class ParallelScrollObservationView: NSView {
    private weak var nativeIdentityOwner: ParallelScrollNativeIdentity?
    private var isTornDown = false
    /// Transfer registration when the representable changes holders; preserve the old holder's
    /// last scoped identity for an observer-only remount.
    func bindNativeIdentity(_ holder: ParallelScrollNativeIdentity?) {
        guard nativeIdentityOwner !== holder else { return }
        nativeIdentityOwner?.unregister(self)
        if nativeIdentityOwner != nil { detachNativeTarget() }
        nativeIdentityOwner = holder
        holder?.register(self)
    }

    var axis = ParallelScrollObserver.Axis.horizontal
    var onPosition: ((CGFloat, CGFloat, CGFloat) -> Void)?
    var onViewportSize: ((CGSize) -> Void)?
    var onNativeViewportGeometry: ((CGSize, CGFloat) -> Void)?
    var onUpwardIntent: (() -> Void)?
    var restorationDiagnostic: ((String) -> Void)?
    /// The reading-anchor provider of the adopted native target, held weakly: it dies with the
    /// lease that created it. Nil for every default observer.
    weak var anchorProvider: ParallelScrollAnchorProvider?
    var followsLive = false
    var onRestorationCancelled: ((ParallelScrollRestorationCancellation) -> Int?)?
    private var restorationGeneration = 0
    private var cancelledGeneration: Int?
    private var wheelMonitor: Any?
    private var liveUserScroll = false
    private var reevaluatingRestoration = false
    private weak var observedScrollView: NSScrollView?
    private weak var observedDocument: NSView?
    private var subscriptions = Set<AnyCancellable>()
    private var documentSubscription: AnyCancellable?
    var horizontalPosition: ParallelViewportPosition?
    var explicitNavigationID: String?
    private var preservedHorizontalOffset: CGFloat?
    private var configuredHorizontalPosition = false
    private var previousNavigationID: String?
    func cancelHorizontalMovement() { pendingOffset = nil; preservedHorizontalOffset = nil }

    private var ids: [String] = []
    private var stride: CGFloat = 0
    private var pendingOffset: CGFloat?
    private var applyingRestoration = false
    private var nativeAnchorTarget: CGFloat?
    private weak var nativeAnchorTargetProvider: ParallelScrollAnchorProvider?
    private var requestedOffset: CGFloat?
    private var restorationActive = false
    private var configuredAxis: ParallelScrollObserver.Axis?
    private var pendingPositionAcknowledgement = false
    private var lastOffset: CGFloat = 0
    private var lastReported: CGRect?
    private var lastViewportSize: CGSize?
    private var lastOuterScrollWidth: CGFloat?
    /// Scoped native identity owns attachment, never an enclosing scroll view.
    var usesNativeIdentity = false
    /// The most recently delivered scoped identity, kept even while it cannot attach yet (a
    /// native document view that has not laid out): the bounded lifecycle events re-attempt it.
    private weak var nativeTarget: NSScrollView?
    /// The borrowed insets state of the currently adopted native target, restored on replacement
    /// or detach while the target is still on a window.
    private var nativeInsetBackup: NativeInsetBackup?
    /// The inset state this observer explicitly zeroes on an adopted native target so the feed's
    /// document keeps plain zero scroll-view content insets — see `enforceNativeInsets(on:)`.
    private struct NativeInsetBackup {
        weak var scrollView: NSScrollView?
        var automaticallyAdjusts: Bool
        var insets: NSEdgeInsets
    }

    /// Direct push from the scoped identity holder — bypasses `configure`'s unchanged-input early
    /// return, so a discovered or replaced List scroll view attaches and reports even when no
    /// configure input changed. An explicit nil detaches the native notifications and wheel
    /// monitor and fails closed; a repeated identical target only reports.
    func adoptNativeIdentity(_ scrollView: NSScrollView?) {
        guard usesNativeIdentity, !isTornDown else { return }
        if nativeTarget !== scrollView { cancelledGeneration = nil }
        nativeTarget = scrollView
        applyNativeIdentity(scrollView)
    }

    /// The bounded lifecycle retry: window and superview moves (and configure's deferred block)
    /// re-attempt the native adoption, or fall back to the enclosing-scroll attachment for every
    /// default observer, whose behaviour is unchanged.
    private func reattach() {
        guard !isTornDown else { return }
        if usesNativeIdentity { applyNativeIdentity(nativeTarget) } else { attach() }
    }

    /// An unchanged target reports; document replacement rebinds frame observation while
    /// preserving insets, wheel monitoring, live gestures and pending restoration.
    /// A temporarily absent document drops only its frame subscription for lifecycle retry.
    /// A different scroll view fully detaches the previous target; nil fails closed.
    /// A replaced document ends an armed anchor provider's reference — its captured native
    /// package is dead — while the temporary nil gap keeps the live gesture listeners.
    private func applyNativeIdentity(_ scrollView: NSScrollView?) {
        guard let scrollView else {
            if observedScrollView != nil { detachNativeTarget() }
            return
        }
        if scrollView === observedScrollView {
            let document = scrollView.documentView
            if document !== observedDocument {
                if document != nil {
                    anchorProvider?.cancelAnchorRestoration()
                    attachDocumentNotifications(for: document)
                    lastReported = nil
                    report(documentGeometryChanged: true)
                } else {
                    cancelLegacyAnchorReference()
                    documentSubscription = nil
                    observedDocument = nil
                }
            } else {
                report()
            }
            return
        }
        detachNativeTarget()
        guard scrollView.documentView != nil else { return }
        observedScrollView = scrollView
        enforceNativeInsets(on: scrollView)
        attachNotifications(for: scrollView)
        updateWheelMonitor()
        report(documentGeometryChanged: true)
    }

    /// Detaches native observation and insets while retaining queued restoration for replacement.
    private func detachNativeTarget() {
        // Only a genuinely held target's reference dies here; the initial adoption passes
        // through with nothing observed and must not end an already-armed provider.
        if observedScrollView != nil { anchorProvider?.cancelAnchorRestoration() }
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        liveUserScroll = false
        restoreNativeInsets()
        observedScrollView = nil
        observedDocument = nil
        nativeAnchorTarget = nil
        lastReported = nil
        lastViewportSize = nil
        lastOuterScrollWidth = nil
    }

    /// Full release at representable dismantle: notifications, wheel monitor, any borrowed
    /// native insets and an armed anchor provider's reference go with the observation view.
    func teardownObservation() {
        isTornDown = true
        cancelHorizontalMovement()
        liveUserScroll = false
        anchorProvider?.cancelAnchorRestoration()
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        restoreNativeInsets()
        observedScrollView = nil
        observedDocument = nil
        lastViewportSize = nil
        lastOuterScrollWidth = nil
    }

    /// Keep adopted List scroll insets zero across layout reports, retaining the original
    /// state for restoration while the native target still has a window.
    ///
    /// Leave native table spacing and sizing to SwiftUI. Mutating them during scroll reports
    /// can repeatedly change row heights and cause visible oscillation on first mount.
    private func enforceNativeInsets(on scroll: NSScrollView) {
        if nativeInsetBackup?.scrollView !== scroll {
            nativeInsetBackup = NativeInsetBackup(
                scrollView: scroll,
                automaticallyAdjusts: scroll.automaticallyAdjustsContentInsets,
                insets: scroll.contentInsets
            )
        }
        if scroll.automaticallyAdjustsContentInsets { scroll.automaticallyAdjustsContentInsets = false }
        let insets = scroll.contentInsets
        if insets.top != 0 || insets.left != 0 || insets.bottom != 0 || insets.right != 0 {
            scroll.contentInsets = NSEdgeInsetsZero
        }
    }

    /// Restores the borrowed insets of the last adopted target, capturing nothing new; an
    /// off-window target is released without writes, mirroring the shared chrome owner's rule.
    private func restoreNativeInsets() {
        guard let backup = nativeInsetBackup else { return }
        nativeInsetBackup = nil
        guard let scroll = backup.scrollView, scroll.window != nil else { return }
        scroll.automaticallyAdjustsContentInsets = backup.automaticallyAdjusts
        scroll.contentInsets = backup.insets
    }

    func configure(ids: [String], stride: CGFloat, restorationOffset: CGFloat?, restorationActive: Bool, generation: Int = 0) {
        let navigationChanged = configuredHorizontalPosition && explicitNavigationID != previousNavigationID
        if axis == .horizontal {
            if !configuredHorizontalPosition {
                pendingOffset = horizontalPosition?.offset
                configuredHorizontalPosition = true
            }
            if navigationChanged { cancelHorizontalMovement() }
            previousNavigationID = explicitNavigationID
        }
        let generationChanged = generation != restorationGeneration
        restorationGeneration = generation
        let suppressed = usesNativeIdentity && axis == .vertical && cancelledGeneration.map { generation <= $0 } == true
        diagnose("configure entry incomingActive=\(restorationActive) incomingOffset=\(String(describing: restorationOffset))")
        let restorationOffset = (suppressed || anchorProvider?.isAnchorRestorationActive == false) ? nil : restorationOffset
        let restorationActive = (suppressed || anchorProvider?.isAnchorRestorationActive == false) ? false : restorationActive
        let geometryChanged = configuredAxis != axis || ids != self.ids || stride != self.stride
        guard generationChanged || geometryChanged || pendingOffset != nil
            || restorationOffset != requestedOffset || restorationActive != self.restorationActive else { return }
        if !restorationActive { pendingPositionAcknowledgement = false }
        if restorationActive, restorationOffset != nil,
           restorationOffset != requestedOffset || restorationActive != self.restorationActive {
            pendingPositionAcknowledgement = true
        }
        configuredAxis = axis
        self.restorationActive = restorationActive
        if axis == .horizontal, !liveUserScroll, !navigationChanged, pendingOffset == nil,
           ids != self.ids || stride != self.stride {
            pendingOffset = preservedHorizontalOffset ?? lastOffset
            preservedHorizontalOffset = self.ids.first.map { _ in preservedHorizontalOffset ?? lastOffset }
        }
        self.ids = ids
        self.stride = stride
        if generationChanged || restorationOffset != requestedOffset {
            requestedOffset = restorationOffset
            if let restorationOffset { pendingOffset = restorationOffset } else if axis == .vertical { pendingOffset = nil }
        }
        diagnose("configure ack")
        DispatchQueue.main.async { [weak self] in self?.reattach(); self?.report() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if axis == .horizontal { pendingOffset = horizontalPosition?.offset ?? pendingOffset }
            liveUserScroll = false
            anchorProvider?.cancelAnchorRestoration()
            subscriptions.removeAll()
            documentSubscription = nil
            removeWheelMonitor()
            restoreNativeInsets()
            observedScrollView = nil
            observedDocument = nil
            lastReported = nil
            lastViewportSize = nil
            lastOuterScrollWidth = nil
        } else { DispatchQueue.main.async { [weak self] in self?.reattach() } }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        DispatchQueue.main.async { [weak self] in self?.reattach() }
    }

    private func attach() {
        // Native-identity mode never attaches through `enclosingScrollView` — that would reach
        // an outer lane or canvas, not the scoped List's own scroll view.
        guard !usesNativeIdentity, window != nil, let scroll = enclosingScrollView, scroll !== observedScrollView,
              scroll.documentView != nil else { return }
        subscriptions.removeAll()
        documentSubscription = nil
        removeWheelMonitor()
        observedScrollView = scroll
        updateWheelMonitor()
        attachNotifications(for: scroll)
        report(documentGeometryChanged: true)
    }

    /// Subscribes the native bounds/frame notifications of one adopted scroll view and its
    /// document — the shared body of both attachment paths — and records the subscribed
    /// document so a same-scroll replacement can be detected later.
    private func attachNotifications(for scroll: NSScrollView) {
        guard let document = scroll.documentView else { return }
        subscriptions.removeAll()
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        for (name, object) in [
            (NSView.boundsDidChangeNotification, scroll.contentView),
            (NSView.frameDidChangeNotification, scroll.contentView)
        ] {
            NotificationCenter.default
                .publisher(for: name, object: object)
                .sink { [weak self] _ in self?.report(observeExternalMovement: name == NSView.boundsDidChangeNotification) }
                .store(in: &subscriptions)
        }
        if usesNativeIdentity || axis == .horizontal {
            scroll.postsFrameChangedNotifications = true
            NotificationCenter.default
                .publisher(for: NSView.frameDidChangeNotification, object: scroll)
                .sink { [weak self] _ in self?.report() }
                .store(in: &subscriptions)
            NotificationCenter.default
                .publisher(for: NSScrollView.willStartLiveScrollNotification, object: scroll)
                .sink { [weak self] _ in
                    self?.liveUserScroll = true
                    if self?.axis == .horizontal { self?.cancelHorizontalMovement() }
                    // A live scroll gesture is real user intent: it ends an armed anchor
                    // provider's reference before any correction can fight the reader's own
                    // position.
                    self?.cancelAnchorReference()
                }
                .store(in: &subscriptions)
            NotificationCenter.default
                .publisher(for: NSScrollView.didEndLiveScrollNotification, object: scroll)
                .sink { [weak self] _ in self?.liveUserScroll = false }
                .store(in: &subscriptions)
        }
        attachDocumentNotifications(for: document)
    }

    /// Moves only the document frame observer; scroll and live-gesture notifications survive
    /// a same-scroll document replacement, including a temporary nil document.
    private func attachDocumentNotifications(for document: NSView?) {
        documentSubscription = nil
        observedDocument = document
        guard let document else { return }
        document.postsFrameChangedNotifications = true
        documentSubscription = NotificationCenter.default
            .publisher(for: NSView.frameDidChangeNotification, object: document)
            .sink { [weak self] _ in self?.report(documentGeometryChanged: true) }
    }

    func updateWheelMonitor() {
        guard onUpwardIntent != nil || (axis == .horizontal && (pendingOffset != nil || preservedHorizontalOffset != nil)),
              observedScrollView?.window != nil else {
            removeWheelMonitor()
            return
        }
        guard wheelMonitor == nil else { return }
        let events: NSEvent.EventTypeMask = usesNativeIdentity || axis == .horizontal
            ? [.scrollWheel, .keyDown, .leftMouseDown] : .scrollWheel
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            self?.observeHorizontalNavigationIntent(event)
            if event.type == .scrollWheel {
                self?.observeWheelIntent(event)
            } else {
                self?.observeNativeNavigationIntent(event)
            }
            return event
        }
    }

    func observeHorizontalNavigationIntent(_ event: NSEvent) {
        guard axis == .horizontal, let scroll = observedScrollView,
              ParallelScrollObserver.isHorizontalNavigation(event, in: scroll) else { return }
        cancelHorizontalMovement()
    }

    func removeWheelMonitor() {
        if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) }
        wheelMonitor = nil
    }

    private func observeWheelIntent(_ event: NSEvent) {
        guard axis == .vertical, let scroll = observedScrollView, event.window === scroll.window,
              scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
              event.momentumPhase.isEmpty,
              event.phase.isEmpty || event.phase.contains(.began) || event.phase.contains(.changed) else { return }
        // Continued wheel movement in either direction is real user intent: it ends an armed
        // anchor provider's reference before the next correction can fight the reader's own
        // position.
        if event.scrollingDeltaY != 0 { cancelAnchorReference(isUpward: event.scrollingDeltaY > 0) }
        if event.scrollingDeltaY > 0, event.phase.isEmpty || event.phase.contains(.began) { signalUpwardIntent() }
    }

    /// Native List navigation signals apply only to this scoped scroll view and never consume
    /// the event. Keyboard navigation must originate from its own first responder subtree.
    func observeNativeNavigationIntent(_ event: NSEvent) {
        guard usesNativeIdentity, !isTornDown, axis == .vertical,
              let scroll = observedScrollView, event.window === scroll.window else { return }
        switch event.type {
        case .keyDown:
            guard let responder = scroll.window?.firstResponder as? NSView,
                  responder === scroll || responder.isDescendant(of: scroll),
                  let character = event.charactersIgnoringModifiers?.unicodeScalars.first?.value else { return }
            if [UInt32(NSUpArrowFunctionKey), UInt32(NSPageUpFunctionKey), UInt32(NSHomeFunctionKey)].contains(character) {
                signalUpwardIntent()
            } else if [UInt32(NSDownArrowFunctionKey), UInt32(NSPageDownFunctionKey), UInt32(NSEndFunctionKey)].contains(character) {
                // Downward navigation is user intent too: it only ends an armed anchor
                // provider's reference, never the upward-intent handling.
                cancelAnchorReference()
            }
        case .leftMouseDown:
            guard let scroller = scroll.verticalScroller,
                  scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) else { return }
            let part = scroller.testPart(event.locationInWindow)
            if part == .decrementPage {
                signalUpwardIntent()
            } else if part == .incrementPage || part == .knob {
                cancelAnchorReference()
            }
        default: break
        }
    }

    /// User input retires the entire native restoration generation before any callback.
    private func cancelAnchorReference(isUpward: Bool = false) {
        guard usesNativeIdentity, axis == .vertical else {
            cancelLegacyAnchorReference()
            return
        }
        let providerActive = anchorProvider?.isAnchorRestorationActive == true
        guard isUpward || !followsLive || providerActive else { return }
        let hadWork = restorationActive || pendingOffset != nil || nativeAnchorTarget != nil || providerActive
        cancelledGeneration = max(cancelledGeneration ?? restorationGeneration, restorationGeneration)
        pendingOffset = nil
        requestedOffset = nil
        nativeAnchorTarget = nil
        nativeAnchorTargetProvider = nil
        restorationActive = false
        pendingPositionAcknowledgement = false
        anchorProvider?.cancelAnchorRestoration()
        if hadWork, let scrollView = observedScrollView,
           let acceptedGeneration = onRestorationCancelled?(ParallelScrollRestorationCancellation(
               observer: self, scrollView: scrollView, generation: restorationGeneration, isUpward: isUpward
           )), observedScrollView === scrollView {
            cancelledGeneration = max(cancelledGeneration ?? restorationGeneration, acceptedGeneration)
        }
    }

    private func cancelLegacyAnchorReference() {
        guard let anchorProvider else { return }
        anchorProvider.cancelAnchorRestoration()
        restorationActive = false
        nativeAnchorTarget = nil
        pendingOffset = nil
        requestedOffset = nil
    }

    private func signalUpwardIntent() {
        cancelAnchorReference(isUpward: true)
        onUpwardIntent?()
    }

    /// Observe an upward reading move before a queued layout restoration can replace it.
    /// Content shrinkage and viewport resizing remain layout changes, not user scroll evidence.
    private func observeExternalUpwardScroll(visible: CGRect, document: NSView, length: CGFloat, viewport: CGFloat) {
        guard axis == .vertical else { return }
        let offset = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
        if usesNativeIdentity, liveUserScroll, offset < lastOffset - 0.5 { signalUpwardIntent() }
        guard axis == .vertical, let lastReported, offset < lastOffset - 0.5,
              abs(length - lastReported.width) < 0.5, viewport == lastReported.height else { return }
        pendingOffset = nil
        requestedOffset = nil
        lastOffset = offset
        self.lastReported = CGRect(x: offset, y: 0, width: length, height: viewport)
        onPosition?(offset, length, viewport)
    }

    private func nativeRestorationTarget(document: NSView, geometryChanged: Bool) -> CGFloat? {
        var providerTarget: CGFloat?
        if axis == .vertical, usesNativeIdentity {
            if anchorProvider?.isAnchorRestorationActive == false {
                pendingOffset = nil
                requestedOffset = nil
                restorationActive = false
                nativeAnchorTarget = nil
            }
            if geometryChanged {
                nativeAnchorTarget = anchorProvider?.immediateAnchorTarget(document: document)
                nativeAnchorTargetProvider = anchorProvider
            }
            if geometryChanged, anchorProvider?.isAnchorRestorationActive == true,
               nativeAnchorTargetProvider === anchorProvider {
                providerTarget = nativeAnchorTarget
            }
            if anchorProvider?.ownsNumericRestoration == true {
                pendingOffset = nil
                requestedOffset = nil
            }
            if providerTarget != nil {
                pendingOffset = nil
                requestedOffset = nil
            }
        }
        return providerTarget
    }

    private func applyRestorationTarget(_ target: CGFloat, scroll: NSScrollView, document: NSView,
                                        geometry: (length: CGFloat, viewport: CGFloat, visible: CGRect)) {
        let (length, viewport, visible) = geometry
        diagnose("apply target=\(target) visible=\(visible.minY) height=\(length) viewport=\(viewport) before")
        pendingOffset = nil
        let clamped = min(max(0, target), max(0, length - viewport))
        var point = scroll.contentView.bounds.origin
        if axis == .horizontal { point.x = clamped } else { point.y = document.isFlipped ? clamped : max(0, document.bounds.maxY - viewport - clamped) }
        if abs((axis == .horizontal ? point.x : point.y) - (axis == .horizontal ? visible.minX : visible.minY)) > 0.5 {
            applyingRestoration = true
            scroll.contentView.scroll(to: point)
            scroll.reflectScrolledClipView(scroll.contentView)
            applyingRestoration = false
        }
        diagnose("apply after target=\(target)")
    }

    func reevaluateAnchorProvider(_ provider: ParallelScrollAnchorProvider) {
        guard !reevaluatingRestoration, anchorProvider === provider, provider.isAnchorRestorationActive,
              observedScrollView?.documentView === observedDocument else { return }
        reevaluatingRestoration = true
        defer { reevaluatingRestoration = false }
        report(documentGeometryChanged: true)
    }

    private func diagnose(_ event: @autoclosure () -> String) {
        guard let restorationDiagnostic else { return }
        let scroll = observedScrollView
        restorationDiagnostic(event() + " native=\(String(describing: scroll.map { ObjectIdentifier($0) }))"
            + " outer=\(scroll?.frame.width ?? 0) clip=\(String(describing: scroll?.contentView.bounds.size))"
            + " style=\(scroll?.scrollerStyle.rawValue ?? -1) preferred=\(NSScroller.preferredScrollerStyle.rawValue)"
            + " offset=\(scroll?.documentVisibleRect.minY ?? 0) height=\(scroll?.documentView?.bounds.height ?? 0)"
            + " rows=\((scroll?.documentView as? NSTableView)?.numberOfRows ?? -1)"
            + " active=\(restorationActive) requested=\(String(describing: requestedOffset))"
            + " pending=\(String(describing: pendingOffset)) ack=\(pendingPositionAcknowledgement)")
    }

    private func reportViewportSize(_ viewportSize: CGSize, scroll: NSScrollView) {
        if usesNativeIdentity, axis == .vertical, let onNativeViewportGeometry {
            let outerWidth = scroll.frame.width
            if viewportSize != lastViewportSize || outerWidth != lastOuterScrollWidth {
                lastViewportSize = viewportSize
                lastOuterScrollWidth = outerWidth
                diagnose("geometry callback entry")
                onNativeViewportGeometry(viewportSize, outerWidth)
                diagnose("geometry callback exit")
            }
        } else if viewportSize != lastViewportSize {
            lastViewportSize = viewportSize
            lastOuterScrollWidth = nil
            onViewportSize?(viewportSize)
        }
    }

    private func clampHorizontalOffset(scroll: NSScrollView, document: NSView, length: CGFloat, viewport: CGFloat) {
        guard axis == .horizontal, !liveUserScroll, !applyingRestoration, viewport > 0,
              scroll.contentView.bounds.minX > max(0, length - viewport) + 0.5 else { return }
        applyRestorationTarget(max(0, length - viewport), scroll: scroll, document: document,
                               geometry: (length, viewport, scroll.documentVisibleRect))
    }

    private func report(observeExternalMovement: Bool = false, documentGeometryChanged: Bool = false) {
        guard !isTornDown, let scroll = observedScrollView, let document = scroll.documentView else { return }
        // Native targets re-assert the zero-inset contract on every report, so a later resize or
        // layout pass that restores an automatic inset cannot shift the feed's document geometry.
        if usesNativeIdentity { enforceNativeInsets(on: scroll) }
        diagnose("report geometry=\(documentGeometryChanged) external=\(observeExternalMovement) live=\(liveUserScroll)")
        let visible = scroll.documentVisibleRect
        let viewportSize = scroll.contentView.bounds.size
        reportViewportSize(viewportSize, scroll: scroll)
        let length = axis == .horizontal ? document.bounds.width : document.bounds.height
        let viewport = axis == .horizontal ? viewportSize.width : viewportSize.height
        // A queued layout report can precede the bounds notification for a user move.
        if observeExternalMovement || liveUserScroll, !applyingRestoration {
            diagnose("external movement entry")
            let incoming = document.isFlipped ? visible.minY : document.bounds.maxY - visible.maxY
            // A downward live move is user intent in the other direction: it ends an armed
            // anchor provider's reference just as an upward move does.
            if liveUserScroll, incoming > lastOffset + 0.5 { cancelAnchorReference() }
            observeExternalUpwardScroll(visible: visible, document: document, length: length, viewport: viewport)
            diagnose("external movement exit")
        }
        // An armed anchor provider corrects from the document's fresh native geometry before
        // this report applies anything, and owns the target over every queued numeric
        // restoration request — those were measured before the structural change and are stale
        // by construction while the provider's mapping stays valid. Computed after external
        // movement observation, so a user move that cancels the provider this same report
        // cannot leave a stale correction to apply.
        let providerTarget = nativeRestorationTarget(document: document, geometryChanged: documentGeometryChanged)
        let horizontalLayoutReady = axis != .horizontal || (!ids.isEmpty && stride > 0 && abs(length - CGFloat(ids.count) * stride) < 2)
        if restorationActive, pendingOffset == nil, let requestedOffset { pendingOffset = requestedOffset }
        if let target = providerTarget ?? preservedHorizontalOffset ?? pendingOffset, viewport > 0, horizontalLayoutReady {
            applyRestorationTarget(target, scroll: scroll, document: document, geometry: (length, viewport, visible))
        }
        if horizontalLayoutReady { clampHorizontalOffset(scroll: scroll, document: document, length: length, viewport: viewport) }
        let updated = scroll.documentVisibleRect
        lastOffset = axis == .horizontal ? updated.minX : (document.isFlipped ? updated.minY : document.bounds.maxY - updated.maxY)
        if axis == .horizontal, horizontalLayoutReady, viewport > 0, pendingOffset == nil {
            horizontalPosition?.offset = max(0, lastOffset)
            preservedHorizontalOffset = preservedHorizontalOffset.map { _ in max(0, lastOffset) }
        }
        let report = CGRect(x: lastOffset, y: 0, width: length, height: viewport)
        let acknowledgesRestoration = pendingPositionAcknowledgement && viewport > 0 && horizontalLayoutReady && pendingOffset == nil
        if acknowledgesRestoration {
            diagnose("position ack")
            pendingPositionAcknowledgement = false
        }
        if report != lastReported || acknowledgesRestoration {
            lastReported = report
            onPosition?(lastOffset, length, viewport)
        }
    }
}
