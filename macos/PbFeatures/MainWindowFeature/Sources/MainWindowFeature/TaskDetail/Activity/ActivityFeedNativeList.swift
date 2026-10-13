//
//  ActivityFeedNativeList.swift
//  MainWindowFeature
//
//  The activity feed's owned native surface: one NSScrollView + NSTableView pair the feed
//  controls outright, with pinned-width NSHostingView roots (one per entry), the measured
//  intercell spacing of the List it replaces (17pt horizontal, 0 vertical), and the TaskDetail
//  (24pt) vs Parallel (0pt) horizontal padding carried by the entries. Every geometry update is
//  one synchronous transaction: resolve the pending older page and its reveal, capture the
//  latest reading, pre-measure the changed heights against the same environment and the same
//  real column width the displayed roots receive, update the table, then perform exactly one
//  owned scroll write when the captured position or live follow actually requires it. There is
//  no generation, reference-lease or provider loop anywhere: the table is the single document,
//  its heights are cached by row revision, column width, environment revision and root-input
//  revision, and an unchanged poll never remeasures or rewrites a retained row.
//
//  Live follow starts on, pauses immediately on genuine upward user intent (wheel, keyboard,
//  any upward native movement) before any position publication, and resumes when real native
//  movement settles back within the 24-point near-bottom band — never during an active scroll
//  gesture, whose pause must outlast momentum. A hosted root's own height reports (local
//  SwiftUI state such as a tool row's expanded toggle) update the affected row in one bounded
//  queued transaction without rewriting any cell, preserving hosted selection, contextual
//  menus and accessibility. Remounts restore the anchor, follow and disclosure state the
//  shared ParallelColumnUIState already persists; a different state object is a different task
//  identity and resets the owner's geometry, paging and realization state. Scrollbar chrome is
//  owned with the view it was created with: overlay, auto-hiding, small, reasserted after a
//  preference or AppKit restyle — nothing to capture or restore.
//

import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - ActivityFeedNativeListMetrics

enum ActivityFeedNativeListMetrics {
    /// The measured horizontal intercell spacing of the plain List this table replaces: the
    /// real NSTableColumn is the clip width minus this value (measured: clip 420 → column 403
    /// → 24pt-padded content 379 at x 20), and every hosted root is pinned to that column
    /// width — measuring at the clip width would wrap text wider than any real cell renders.
    static let horizontalIntercellSpacing: CGFloat = 17
}

// MARK: - ActivityFeedNativeItemBox

/// One entry's mutable measurement state. The height cache key is the entry's render revision,
/// the pinned column width, the environment revision and the root-input revision — anything
/// else leaves it untouched.
@MainActor final class ActivityFeedNativeItemBox {
    var entry: ActivityFeedNativeEntry
    var revision: Int
    var height: CGFloat?
    var measurementKey: ActivityFeedNativeMeasurementKey?

    init(entry: ActivityFeedNativeEntry, revision: Int) {
        self.entry = entry
        self.revision = revision
    }
}

// MARK: - ActivityFeedNativeScrollView

@MainActor final class ActivityFeedNativeScrollView: NSScrollView {
    weak var owner: ActivityFeedNativeList.Coordinator?

    override func scrollWheel(with event: NSEvent) {
        // Genuine wheel intent: classified before AppKit applies the movement, so an upward
        // wheel pauses live follow before any position publication.
        owner?.noteUserScrollEvent()
        owner?.noteWheelIntent(event)
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handleOwnedKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { owner?.schedulePositioningCheck() }
    }
}

// MARK: - ActivityFeedNativeScroller

/// Keeps AppKit's native tracking and actions while identifying the owned scrollbar gesture.
@MainActor class ActivityFeedNativeScroller: NSScroller {
    override class var isCompatibleWithOverlayScrollers: Bool { true }

    weak var owner: ActivityFeedNativeList.Coordinator?
    private var previousTrackingValue: Double = 0

    override func mouseDown(with event: NSEvent) {
        previousTrackingValue = doubleValue
        owner?.isScrollerTracking = true
        defer { owner?.isScrollerTracking = false }
        super.mouseDown(with: event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        let upward = hitPart == .decrementLine || hitPart == .decrementPage
            || (hitPart == .knob && doubleValue < previousTrackingValue)
        if upward {
            owner?.noteUserScrollEvent()
            owner?.noteUpwardIntent()
        }
        previousTrackingValue = doubleValue
        return super.sendAction(action, to: target)
    }
}

// MARK: - ActivityFeedNativeTableView

@MainActor final class ActivityFeedNativeTableView: NSTableView {
    weak var owner: ActivityFeedNativeList.Coordinator?

    override func pageUp(_ sender: Any?) {
        owner?.noteUserScrollEvent()
        super.pageUp(sender)
    }

    override func pageDown(_ sender: Any?) {
        owner?.noteUserScrollEvent()
        super.pageDown(sender)
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handleOwnedKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// A row view that never draws selection: the feed's rows are reading content, and their hosted
/// text keeps its own selection, contextual menus and accessibility.
@MainActor final class ActivityFeedNativeRowView: NSTableRowView {
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func drawSelection(in _: NSRect) {}
}

// MARK: - ActivityFeedNativeList

/// The native table representable. `updateNSView` runs the reconcile transaction for every
/// SwiftUI update — including updates whose inputs are equal, so the hosted action callbacks
/// are always current and the stored environment never goes stale.
struct ActivityFeedNativeList: NSViewRepresentable {
    let model: ActivityFeedNativeModel
    let state: ParallelColumnUIState
    let actions: ActivityFeedNativeActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ActivityFeedNativeScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.verticalScroller = ActivityFeedNativeScroller(frame: NSRect(x: 0, y: 0, width: 15, height: 100))
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let table = ActivityFeedNativeTableView()
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .none
        table.gridStyleMask = []
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsColumnSelection = false
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .medium
        // The measured intercell spacing of the plain List this table replaces.
        table.intercellSpacing = CGSize(width: ActivityFeedNativeListMetrics.horizontalIntercellSpacing, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ActivityFeed"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        scroll.documentView = table
        context.coordinator.install(scroll: scroll, table: table)
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.update(model: model, state: state, environment: context.environment, actions: actions)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    // MARK: - Coordinator

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let actions = ActivityFeedNativeActions()
        weak var scroll: ActivityFeedNativeScrollView?
        weak var table: ActivityFeedNativeTableView?
        var model: ActivityFeedNativeModel?
        var previousModel: ActivityFeedNativeModel?
        var state: ParallelColumnUIState?
        var entries: [ActivityFeedNativeEntry] = []
        var boxes: [ActivityFeedNativeItemBox] = []
        var cells: [String: ActivityFeedNativeCell] = [:]
        var measurementHost: NSHostingView<ActivityFeedNativeRowRoot>?
        var environment = EnvironmentValues()
        var environmentRevision = 0
        var rootInputsRevision = 0
        var fingerprint: ActivityFeedNativeEnvironmentFingerprint?
        var width: CGFloat = 0
        var firstRowIndex: Int?
        var lastRowIndex: Int?
        var positioned = false
        var needsInitialPosition = true
        var reconciling = false
        var programmaticScrollDepth = 0
        var mountedIDs: Set<String> = []
        var shortFill = ActivityShortFillBudget()
        var pendingPage: ActivityFeedNativePendingPage?
        var pendingPageObservedLoading = false
        var rejectedIDs: [String]?
        var lastObservedMinY: CGFloat = 0
        var lastViewportHeight: CGFloat = 0
        var pendingUserScrollEvent = false
        var isLiveScrolling = false
        var isScrollerTracking = false
        var pendingNativeCapture: ActivityFeedNativeReadingCapture?
        var heldPagingOffset: CGFloat?
        var pendingHostedHeights: [String: ActivityFeedNativeHostedHeightReport] = [:]
        var hostedHeightFlushQueued = false
        var bottomRepinQueued = false
        var positioningCheckQueued = false
        var chromeReassertQueued = false
        var observers: [NSObjectProtocol] = []
        var scrollerObservation: NSKeyValueObservation?

        // MARK: Lifecycle

        func install(scroll: ActivityFeedNativeScrollView, table: ActivityFeedNativeTableView) {
            self.scroll = scroll
            self.table = table
            scroll.owner = self
            (scroll.verticalScroller as? ActivityFeedNativeScroller)?.owner = self
            table.owner = self
            table.dataSource = self
            table.delegate = self
            // The coordinator owns the retry action: its paging state machine lives beside it.
            actions.retry = { [weak self] in self?.requestPage(retry: true) }
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            // Bounds, live-scroll and style notifications are delivered synchronously — every
            // poster here is the main thread — so a gesture's position is published before the
            // next line of owner code runs, and an incoherent document is detected while it is
            // actually missing. Frame changes keep their deferred delivery: they fire inside
            // AppKit's own layout pass.
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleBoundsChange() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.handleViewportFrameChange() }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: scroll, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLiveScrolling = true }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification, object: scroll, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.isLiveScrolling = false }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyOwnedChrome() }
            })
            scrollerObservation = scroll.observe(\.scrollerStyle) { [weak self, weak scroll] _, _ in
                MainActor.assumeIsolated { self?.queueChromeReassert(for: scroll) }
            }
        }

        func stop() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            scrollerObservation?.invalidate()
            scrollerObservation = nil
            table?.dataSource = nil
            table?.delegate = nil
            table?.owner = nil
            scroll?.owner = nil
            (scroll?.verticalScroller as? ActivityFeedNativeScroller)?.owner = nil
            isScrollerTracking = false
            cells.removeAll()
            boxes.removeAll()
            entries.removeAll()
            measurementHost = nil
            mountedIDs.removeAll()
            pendingPage = nil
            pendingPageObservedLoading = false
            rejectedIDs = nil
            pendingNativeCapture = nil
            heldPagingOffset = nil
            pendingHostedHeights.removeAll()
            actions.reset()
            scroll = nil
            table = nil
        }

        // MARK: Chrome

        /// The feed owns its scroll view, so its chrome is owned too: overlay, auto-hiding,
        /// small — the presentation the shared chrome owner applies — reasserted whenever the
        /// preferred style changes or AppKit restyles the view to legacy. There is no original
        /// chrome to capture or restore; the view is destroyed with the feed.
        func applyOwnedChrome() {
            guard let scroll else { return }
            if scroll.scrollerStyle != .overlay { scroll.scrollerStyle = .overlay }
            if !scroll.autohidesScrollers { scroll.autohidesScrollers = true }
            if scroll.hasVerticalScroller, scroll.verticalScroller?.controlSize != .small {
                scroll.verticalScroller?.controlSize = .small
            }
        }

        func queueChromeReassert(for observedScroll: NSScrollView?) {
            guard observedScroll === scroll, scroll?.scrollerStyle != .overlay, !chromeReassertQueued else { return }
            chromeReassertQueued = true
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self else { return }
                chromeReassertQueued = false
                applyOwnedChrome()
            }
        }

        // MARK: Update entry point

        func update(model: ActivityFeedNativeModel, state: ParallelColumnUIState, environment: EnvironmentValues,
                    actions: ActivityFeedNativeActions) {
            // Callbacks are refreshed on every SwiftUI update, including input-equal ones.
            self.actions.onLoadMore = actions.onLoadMore
            self.actions.onDisclosure = actions.onDisclosure
            self.actions.onSelectChildTask = actions.onSelectChildTask
            let previous = self.model
            let stateChanged = self.state !== state
            // The supported public inherited environment is stored on every update: a change that
            // leaves the height fingerprint equal may still carry style values the displayed
            // roots must see, so a later refresh must never render a stale capture.
            self.environment = environment
            let nextFingerprint = ActivityFeedNativeEnvironmentFingerprint(environment)
            let environmentChanged = fingerprint != nextFingerprint
            fingerprint = nextFingerprint
            let rootInputsChanged = previous.map {
                $0.start != model.start || $0.horizontalPadding != model.horizontalPadding
                    || $0.showsPromptBubble != model.showsPromptBubble
            } ?? false
            previousModel = previous
            self.model = model
            if stateChanged {
                self.state = state
                resetForStateOwnerChange()
            }
            if environmentChanged {
                environmentRevision += 1
                for box in boxes { box.measurementKey = nil }
            }
            if rootInputsChanged {
                rootInputsRevision += 1
                for box in boxes { box.measurementKey = nil }
            }
            if let previous, previous.paginationRevision != model.paginationRevision {
                pendingPage = nil
                pendingPageObservedLoading = false
                rejectedIDs = nil
                if !model.allRowIDs.isEmpty { self.state?.retainedFirstID = model.allRowIDs.first }
            }
            if previous?.history != model.history { rejectedIDs = nil }
            if previous?.expandedGroups != model.expandedGroups { shortFill.replenish() }
            reconcile(environmentHeightsInvalidated: environmentChanged || rootInputsChanged,
                      rootsNeedRefresh: environmentChanged || rootInputsChanged)
        }

        /// A different state object is a different task identity: the owner's geometry, paging
        /// and realization state belong to the previous document. The new state carries its own
        /// anchor, follow and disclosure, which positioning restores; a remount whose state
        /// object is the same persists all of it, and nothing here runs.
        private func resetForStateOwnerChange() {
            pendingPage = nil
            pendingPageObservedLoading = false
            rejectedIDs = nil
            mountedIDs.removeAll()
            pendingNativeCapture = nil
            heldPagingOffset = nil
            pendingHostedHeights.removeAll()
            shortFill = ActivityShortFillBudget()
            needsInitialPosition = true
            positioned = false
            lastObservedMinY = scroll?.documentVisibleRect.minY ?? 0
        }
    }
}
