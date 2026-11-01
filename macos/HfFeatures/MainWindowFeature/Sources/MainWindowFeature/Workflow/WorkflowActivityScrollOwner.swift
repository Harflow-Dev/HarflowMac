import AppKit
import SwiftUI

// MARK: - WorkflowActivityScrollOwner

/// One document, one displayed hosting root and one native position writer.
@MainActor final class WorkflowActivityScrollOwner {
    private(set) weak var scroll: WorkflowActivityNativeScrollView?
    private(set) var document: WorkflowActivityDocumentView?
    private(set) var host: NSHostingView<WorkflowActivityHostedRoot>?
    private(set) var reading = WorkflowActivityReadingState()
    private(set) var positioned = false
    private(set) var programmaticScrollDepth = 0
    private(set) var rootAssignmentCount = 0
    private(set) var measurementCount = 0
    private(set) var followPublicationCount = 0
    private(set) var attachmentGeneration = 0
    private var presentation: WorkflowActivityPresentation?
    private var environment: ActivityFeedNativeEnvironment?
    private var fingerprint: ActivityFeedNativeEnvironmentFingerprint?
    private var actions: WorkflowActivityActions?
    private var observers: [NSObjectProtocol] = []
    private var styleObservation: NSKeyValueObservation?
    private var queued: Task<Void, Never>?
    private var publication: Task<Void, Never>?
    private var publishedFollowing = true
    private var rootDirty = true
    private var measureDirty = true
    private var width: CGFloat = 0
    private var revision = 0
    private var pendingHeight: CGFloat?
    private var reconciling = false
    private var dispatchDepth = 0
    private var inputOffset: CGFloat = 0

    var following: Bool { reading.following }
    var readingOffset: CGFloat { reading.offset }
    var isInteracting: Bool { reading.interacting || dispatchDepth > 0 }
    var pendingInput: Bool { reading.pendingInput }

    func install(scroll: WorkflowActivityNativeScrollView, actions: WorkflowActivityActions) {
        self.scroll = scroll
        self.actions = actions
        let document = WorkflowActivityDocumentView()
        self.document = document
        scroll.owner = self
        scroll.identifier = NSUserInterfaceItemIdentifier("workflow-native-activity")
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        let scroller = WorkflowActivityNativeScroller()
        scroller.owner = self
        scroll.verticalScroller = scroller
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.documentView = document
        applyChrome()
        actions.jump = { [weak self] in self?.resumeFollowing() }
        actions.height = { [weak self] height, revision, generation in
            self?.onHostedHeight(height, revision: revision, generation: generation)
        }
        attachmentChanged()
    }

    func update(presentation: WorkflowActivityPresentation, environment: EnvironmentValues) {
        let nextFingerprint = ActivityFeedNativeEnvironmentFingerprint(environment)
        if self.presentation != presentation || fingerprint != nextFingerprint {
            self.presentation = presentation
            self.environment = ActivityFeedNativeEnvironment(environment)
            fingerprint = nextFingerprint
            rootDirty = true
            measureDirty = true
            scheduleReconcile()
        }
    }

    /// Native window detach preserves this owner's reading; representable removal calls stop.
    func attachmentChanged() {
        removeObservations()
        attachmentGeneration += 1
        queued?.cancel()
        queued = nil
        publication?.cancel()
        publication = nil
        reading.endInteractions()
        dispatchDepth = 0
        guard let scroll, let document, scroll.window != nil else { return }
        rootDirty = true
        measureDirty = true
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        document.postsFrameChangedNotifications = true
        let generation = attachmentGeneration
        observe(NSView.boundsDidChangeNotification, object: scroll.contentView, generation: generation) { $0.boundsChanged() }
        observe(NSView.frameDidChangeNotification, object: scroll.contentView, generation: generation) { $0.scheduleReconcile() }
        observe(NSView.frameDidChangeNotification, object: document, generation: generation) {
            if !$0.reconciling { $0.scheduleReconcile() }
        }
        observe(NSScrollView.willStartLiveScrollNotification, object: scroll, generation: generation) { $0.beginLiveScroll() }
        observe(NSScrollView.didLiveScrollNotification, object: scroll, generation: generation) { $0.observeUserPosition() }
        observe(NSScrollView.didEndLiveScrollNotification, object: scroll, generation: generation) { $0.endLiveScroll() }
        observe(NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, generation: generation) { $0.applyChrome() }
        styleObservation = scroll.observe(\.scrollerStyle) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyChrome() }
        }
        scheduleReconcile()
    }

    private func observe(_ name: Notification.Name, object: Any?, generation: Int,
                         action: @escaping @MainActor (WorkflowActivityScrollOwner) -> Void) {
        observers.append(NotificationCenter.default.addObserver(forName: name, object: object, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.attachmentGeneration == generation else { return }
                action(self)
            }
        })
    }

    private func removeObservations() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        styleObservation?.invalidate()
        styleObservation = nil
    }

    func stop() {
        removeObservations()
        attachmentGeneration += 1
        queued?.cancel()
        queued = nil
        publication?.cancel()
        publication = nil
        reading.endInteractions()
        actions?.reset()
        actions = nil
        (scroll?.verticalScroller as? WorkflowActivityNativeScroller)?.owner = nil
        scroll?.owner = nil
        host = nil
        document = nil
        scroll = nil
    }

    private func applyChrome() {
        guard let scroll else { return }
        if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
        scroll.autohidesScrollers = true
        scroll.verticalScroller?.controlSize = .small
    }

    func scheduleReconcile() {
        guard queued == nil, scroll?.window != nil else { return }
        let generation = attachmentGeneration
        queued = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, generation == attachmentGeneration else { return }
            queued = nil
            reconcile()
        }
    }

    func onHostedHeight(_ height: CGFloat, revision: Int, generation: Int? = nil) {
        guard generation == nil || generation == attachmentGeneration,
              revision == self.revision, height.isFinite, height >= 0,
              abs(height - (document?.frame.height ?? 0)) > 0.5 else { return }
        pendingHeight = height
        if !reconciling { scheduleReconcile() }
    }

    func reconcile() {
        guard !reconciling, let scroll, let document, scroll.window != nil,
              !scroll.isHiddenOrHasHiddenAncestor, scroll.contentView.bounds.width > 0,
              let presentation, let environment, let actions else { return }
        reconciling = true
        defer {
            reconciling = false
            if let pendingHeight, abs(pendingHeight - document.frame.height) > 0.5 {
                scheduleReconcile()
            } else { pendingHeight = nil }
        }
        let nextWidth = scroll.contentView.bounds.width
        if abs(nextWidth - width) > 0.5 {
            width = nextWidth
            rootDirty = true
            measureDirty = true
        }
        if rootDirty {
            revision += 1
            pendingHeight = nil
            let root = WorkflowActivityHostedRoot(presentation: presentation, environment: environment,
                                                  actions: actions, width: width, revision: revision,
                                                  attachmentGeneration: attachmentGeneration)
            if let host { host.rootView = root } else {
                let host = NSHostingView(rootView: root)
                host.sizingOptions = [.intrinsicContentSize]
                document.addSubview(host)
                self.host = host
            }
            rootAssignmentCount += 1
            rootDirty = false
        }
        let previousHeight = document.frame.height
        if measureDirty || pendingHeight != nil {
            pendingHeight = nil
            guard let host else { return }
            host.frame.size.width = width
            host.layoutSubtreeIfNeeded()
            measurementCount += 1
            let height = host.fittingSize.height
            guard height.isFinite, height >= 0 else { return }
            document.frame = CGRect(x: 0, y: 0, width: width, height: height)
            host.frame = document.bounds
            measureDirty = false
        }
        positionAfterLayout(previousHeight: previousHeight)
    }

    private func positionAfterLayout(previousHeight: CGFloat) {
        guard let scroll, let document, scroll.contentView.bounds.height > 0 else { return }
        if !isInteracting {
            if !reading.following, document.frame.height < previousHeight {
                reading.positioned(at: min(reading.offset, maxOffset))
                reading.settle(contentHeight: document.frame.height, viewportHeight: scroll.contentView.bounds.height)
            }
            writeOffset(reading.following ? maxOffset : reading.offset)
            positioned = true
        }
        publishFollowing()
    }

    private var maxOffset: CGFloat {
        max(0, (document?.frame.height ?? 0) - (scroll?.contentView.bounds.height ?? 0))
    }

    private func writeOffset(_ value: CGFloat) {
        guard let scroll else { return }
        let target = min(max(0, value), maxOffset)
        programmaticScrollDepth += 1
        defer { programmaticScrollDepth -= 1 }
        if abs(scroll.documentVisibleRect.minY - target) > 0.5 {
            scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        reading.positioned(at: target)
    }

    func boundsChanged() {
        guard programmaticScrollDepth == 0, !reconciling else { return }
        if pendingInput { observeUserPosition() } else { scheduleReconcile() }
    }

    func beginInput(upward: Bool) {
        guard scroll?.window != nil, scroll?.isHiddenOrHasHiddenAncestor == false else { return }
        if dispatchDepth == 0 { inputOffset = scroll?.documentVisibleRect.minY ?? reading.offset }
        dispatchDepth += 1
        reading.beginInput(upward: upward)
        publishFollowing()
    }

    func endInput() {
        defer { reading.consumeInput() }
        guard dispatchDepth > 0 else { return }
        observeUserPosition()
        dispatchDepth -= 1
        guard dispatchDepth == 0 else { return }
        reading.endInput(contentHeight: document?.frame.height ?? 0, viewportHeight: scroll?.contentView.bounds.height ?? 0)
        publishFollowing()
        scheduleReconcile()
    }

    func observeUserPosition() {
        guard programmaticScrollDepth == 0, !reconciling, let scroll,
              scroll.window != nil, !scroll.isHiddenOrHasHiddenAncestor else { return }
        let offset = scroll.documentVisibleRect.minY
        let baseline = dispatchDepth > 0 ? inputOffset : reading.offset
        reading.userPosition(offset, upward: offset < baseline - 0.5, downward: offset > baseline + 0.5)
        inputOffset = offset
        if !isInteracting {
            reading.settle(contentHeight: document?.frame.height ?? 0, viewportHeight: scroll.contentView.bounds.height)
        }
        publishFollowing()
        scheduleReconcile()
    }

    func beginLiveScroll() { reading.setLiveScrolling(true) }
    func endLiveScroll() {
        reading.setLiveScrolling(false)
        settleInput()
    }

    func setScrollerTracking(_ value: Bool) {
        reading.setScrollerTracking(value)
        if !value { settleInput() }
    }

    func wheelPhase(_ event: NSEvent) {
        if event.phase.contains(.began) || event.phase.contains(.changed) { reading.setWheelTracking(true) }
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) { reading.setWheelTracking(false) }
        if event.momentumPhase.contains(.began) || event.momentumPhase.contains(.changed) { reading.setMomentum(true) }
        if event.momentumPhase.contains(.ended) || event.momentumPhase.contains(.cancelled) { reading.setMomentum(false) }
    }

    private func settleInput() {
        reading.settle(contentHeight: document?.frame.height ?? 0, viewportHeight: scroll?.contentView.bounds.height ?? 0)
        publishFollowing()
        scheduleReconcile()
    }

    func resumeFollowing() {
        reading.resumeFollowing()
        publishFollowing()
        scheduleReconcile()
    }

    private func publishFollowing() {
        guard publication == nil, reading.following != publishedFollowing else { return }
        let generation = attachmentGeneration
        publication = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, attachmentGeneration == generation else { return }
            publication = nil
            guard reading.following != publishedFollowing else { return }
            publishedFollowing = reading.following
            followPublicationCount += 1
            actions?.following(reading.following)
        }
    }

    /// Mirrors native activity navigation: only this feed's unmodified non-editor responder chain.
    func handleKey(_ event: NSEvent) -> Bool {
        guard let scroll, event.window === scroll.window, positioned,
              !(event.window?.firstResponder is NSTextView),
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              let responder = event.window?.firstResponder as? NSView,
              responder === scroll || responder.isDescendant(of: scroll),
              let characters = event.charactersIgnoringModifiers else { return false }
        let target: CGFloat
        let upward: Bool
        switch characters {
        case "\u{F72C}": target = reading.offset - max(1, scroll.contentView.bounds.height - scroll.verticalPageScroll); upward = true
        case "\u{F72D}": target = reading.offset + max(1, scroll.contentView.bounds.height - scroll.verticalPageScroll); upward = false
        case "\u{F729}": target = 0; upward = true
        case "\u{F72B}": target = maxOffset; upward = false; reading.resumeFollowing()
        case "\u{F700}": target = reading.offset - max(1, scroll.verticalLineScroll); upward = true
        case "\u{F701}": target = reading.offset + max(1, scroll.verticalLineScroll); upward = false
        default: return false
        }
        beginInput(upward: upward)
        defer { endInput() }
        // This is an owned navigation command, so its guarded write is followed by an
        // explicit user-position report rather than relying on a geometry notification.
        writeOffset(target)
        return true
    }

}
