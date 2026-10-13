//
//  ActivityFeedNativeObservation.swift
//  MainWindowFeature
//
//  The native feed's observation and intent layer: scroll and viewport observation gated by
//  visibility, the wheel/keyboard intent classifier, the live-follow band and the bottom
//  re-pin, viewport width/height transactions, older-page request and commit resolution, and
//  the hosted-height reports a row's own local SwiftUI state produces. Every report is applied
//  in one bounded queued transaction; no classification reacts to the owner's own writes.
//

import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - Hosted height reports

/// One coalesced hosted-height report, bound to the box revision whose content produced it.
struct ActivityFeedNativeHostedHeightReport {
    weak var cell: ActivityFeedNativeCell?
    let height: CGFloat
    let revision: Int
}

// MARK: - Observation

extension ActivityFeedNativeList.Coordinator {
    /// Real native movement. A missing or detached native document holds everything: the last
    /// coherent reading and any paging intent the move carried are held, and the move stays
    /// inert — no intent classification, no paging, no boundary change, no position publication.
    /// Visibility gates every remaining state change: a hidden feed's own reflows and writes
    /// never classify as reading intent, resume following, reveal rows or publish a position —
    /// only the tracking baseline advances, so the first observed movement after reappearing
    /// is not misread as upward.
    func handleBoundsChange() {
        guard let scroll, let table else { return }
        let visible = scroll.documentVisibleRect
        guard scroll.documentView === table else {
            holdIncoherentMovement(visible)
            return
        }
        if pendingNativeCapture != nil || heldPagingOffset != nil { resumeHeldReading() }
        guard model?.visible == true else {
            lastObservedMinY = visible.minY
            return
        }
        maybePerformInitialPositioning()
        guard positioned else { publishPosition(); return }
        guard visible.height > 0 else { return }
        let programmatic = programmaticScrollDepth > 0
        let wheelEvent = pendingUserScrollEvent
        pendingUserScrollEvent = false
        guard !programmatic, !reconciling else {
            lastObservedMinY = visible.minY
            return
        }
        // Paging can synchronously install a loading header. Publish this actual movement
        // first so that transaction restores the reader's new anchor, not the previous one.
        // If its native cell is not realized, publishPosition retains the last coherent anchor.
        publishPosition()
        classifyObservedMovement(visible: visible, table: table, wheelEvent: wheelEvent)
        lastObservedMinY = scroll.documentVisibleRect.minY
        publishPosition()
    }

    /// A missing or detached native document holds everything: the last coherent reading and
    /// any paging intent the move carried are held, and the move stays inert — no intent
    /// classification, no paging, no boundary change, no position publication.
    private func holdIncoherentMovement(_ visible: CGRect) {
        if pendingNativeCapture == nil { pendingNativeCapture = latestReading() }
        if visible.minY < lastObservedMinY - 0.5 { heldPagingOffset = visible.minY }
        lastObservedMinY = visible.minY
    }

    /// Real observed movement: upward movement is reading intent and pauses live follow;
    /// movement that settles within the near-bottom band resumes it — during an active scroll
    /// gesture only a downward move may re-enter the zone; a pause that sticks pins the
    /// reading boundary; and a re-armed follower with a gap below it schedules one re-pin.
    private func classifyObservedMovement(visible: CGRect, table: ActivityFeedNativeTableView, wheelEvent: Bool) {
        let movedUp = visible.minY < lastObservedMinY - 0.5
            || (wheelEvent && visible.minY < lastObservedMinY)
        let movedDown = visible.minY > lastObservedMinY + 0.5
        if movedUp { noteUpwardIntent() }
        // Ordinary native position changes retain the 24pt follow band. Explicit upward
        // wheel/live gestures stay paused even inside it; owned keys classify separately.
        let upwardGesture = movedUp && (wheelEvent || isLiveScrolling || isScrollerTracking)
        if !upwardGesture, !isLiveScrolling || movedDown {
            state?.followLive.observe(offset: visible.minY,
                                     contentHeight: table.bounds.height,
                                     viewportHeight: visible.height)
        }
        pinReadingBoundaryIfNeeded()
        maybeLoadOlder()
        if state?.followLive.isFollowing == true, table.bounds.height - visible.maxY > 0.5 {
            scheduleBottomRepin()
        }
    }

    /// The reading boundary is pinned only once a pause sticks — never for an in-band jitter
    /// that live follow immediately re-arms.
    private func pinReadingBoundaryIfNeeded() {
        guard let state, let model, !state.followLive.isFollowing, state.retainedFirstID == nil,
              let first = model.shownRows.first else { return }
        state.retainedFirstID = first.id
    }

    /// Viewport frame changes: a width change is one full transaction; a height change keeps
    /// the paused reading anchor or, while following, keeps the live bottom pinned.
    func handleViewportFrameChange() {
        guard let scroll else { return }
        maybePerformInitialPositioning()
        let newWidth = max(0, scroll.contentView.bounds.width)
        let newHeight = scroll.contentView.bounds.height
        let previousHeight = lastViewportHeight
        let heightChanged = previousHeight > 0 && abs(newHeight - previousHeight) > 0.5
        lastViewportHeight = newHeight
        guard !reconciling else { return }
        if width == 0, newWidth > 0 {
            width = newWidth
            applyColumnWidth(newWidth)
            return
        }
        if abs(newWidth - width) > 0.5, newWidth > 0 {
            performWidthChangeTransaction(newWidth: newWidth)
        } else if heightChanged, positioned {
            if state?.followLive.isFollowing == true {
                writeBottom()
                publishPosition()
            } else if let anchor = state?.anchor {
                restoreAnchor(anchor)
                publishPosition()
            }
        }
    }

    /// One transaction for a width change: capture the latest reading before any geometry
    /// mutation, set the real column width, invalidate and re-measure every height, reload,
    /// then exactly one restore write against the fresh layout.
    func performWidthChangeTransaction(newWidth: CGFloat) {
        guard let state, !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        let following = state.followLive.isFollowing
        let captured = positioned && !following ? latestReading() : nil
        width = newWidth
        applyColumnWidth(newWidth)
        invalidateAllHeights()
        for box in boxes { box.height = nil }
        table?.reloadData()
        layoutNow()
        if positioned, following {
            writeBottom()
        } else if positioned, let captured {
            restore(captured)
        }
        publishPosition()
    }

    // MARK: Follow intent

    func noteUserScrollEvent() {
        pendingUserScrollEvent = true
    }

    /// The owned feed's wheel classifier: an upward wheel is reading intent, suspended before
    /// AppKit applies the movement and publishes any position. A later real movement that
    /// settles within the near-bottom band re-arms follow.
    func noteWheelIntent(_ event: NSEvent) {
        pendingUserScrollEvent = true
        guard event.scrollingDeltaY > 0 else { return }
        noteUpwardIntent()
    }

    /// Genuine upward intent: pause live follow immediately, replenish the short-fill budget
    /// and clear a stale rejection. Visibility gates the whole path before any state change —
    /// a hidden feed's wheel must never pause it.
    func noteUpwardIntent() {
        guard let state, let model else { return }
        guard model.visible else { return }
        if state.followLive.isFollowing { state.followLive.suspend() }
        guard positioned, pendingPage == nil, !model.history.isLoading else { return }
        shortFill.replenish()
        rejectedIDs = nil
        if let table, let scroll, table.bounds.height <= scroll.contentView.bounds.height + 1 {
            maybeLoadOlder()
        }
    }

    /// One queued owned write that re-pins the live bottom after a real in-band movement while
    /// following. Queued — never synchronous — so the movement itself lands first; deduplicated
    /// so overlapping movements produce one write.
    func scheduleBottomRepin() {
        guard !bottomRepinQueued else { return }
        bottomRepinQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            bottomRepinQueued = false
            guard let state, state.followLive.isFollowing, !reconciling else { return }
            writeBottom()
            publishPosition()
        }
    }

    /// The owned feed's unmodified navigation keys: PageUp/PageDown move by the viewport
    /// less the native page overlap; Home/End go to the document
    /// edges, and the vertical arrows scroll by line. Modified keys, every other character,
    /// and any event whose first responder is a text editor pass through untouched.
    func handleOwnedKey(_ event: NSEvent) -> Bool {
        // A text editor holding the keyboard keeps its own navigation; the feed sees the event
        // only when it owns the responder chain, so its selection is never scrolled away.
        if event.window?.firstResponder is NSTextView { return false }
        guard let scroll, let state, let model, model.visible, positioned,
              event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
              let characters = event.charactersIgnoringModifiers
        else { return false }
        switch characters {
        case "\u{F72C}": // Page Up
            noteUpwardIntent()
            pendingUserScrollEvent = true
            scrollBy(-max(1, scroll.contentView.bounds.height - scroll.verticalPageScroll))
            finishOwnedNavigation(upward: true)
            return true
        case "\u{F72D}": // Page Down
            pendingUserScrollEvent = true
            scrollBy(max(1, scroll.contentView.bounds.height - scroll.verticalPageScroll))
            finishOwnedNavigation(upward: false)
            return true
        case "\u{F729}": // Home
            noteUpwardIntent()
            pendingUserScrollEvent = true
            writeOffset(0)
            finishOwnedNavigation(upward: true)
            return true
        case "\u{F72B}": // End
            pendingUserScrollEvent = true
            writeBottom()
            if let table {
                state.followLive.observe(offset: scroll.documentVisibleRect.minY,
                                         contentHeight: table.bounds.height,
                                         viewportHeight: scroll.contentView.bounds.height)
            }
            return true
        case "\u{F700}": // Up arrow
            noteUpwardIntent()
            pendingUserScrollEvent = true
            scrollBy(-max(1, scroll.verticalLineScroll))
            finishOwnedNavigation(upward: true)
            return true
        case "\u{F701}": // Down arrow
            pendingUserScrollEvent = true
            scrollBy(max(1, scroll.verticalLineScroll))
            finishOwnedNavigation(upward: false)
            return true
        default:
            return false
        }
    }

    private func finishOwnedNavigation(upward: Bool) {
        guard let scroll, let table else { return }
        pendingUserScrollEvent = false
        if !upward {
            state?.followLive.observe(offset: scroll.documentVisibleRect.minY,
                                     contentHeight: table.bounds.height,
                                     viewportHeight: scroll.contentView.bounds.height)
        }
        pinReadingBoundaryIfNeeded()
        publishPosition()
        maybeLoadOlder()
    }

    func scrollBy(_ delta: CGFloat) {
        guard let scroll else { return }
        writeOffset(scroll.documentVisibleRect.minY + delta)
    }

    // MARK: Older-page requests

    /// Reveals retained rows or opens the next bounded older-page request when the reading
    /// edge reaches the load window. Returns whether it acted; one request outstanding stops
    /// any repetition. `overrideOffset` evaluates a held intent at the offset it reached.
    @discardableResult
    func maybeLoadOlder(at overrideOffset: CGFloat? = nil) -> Bool {
        guard let model, let state, let scroll, let table, positioned, pendingPage == nil else { return false }
        let visible = scroll.documentVisibleRect
        let viewport = visible.height
        guard viewport > 0 else { return false }
        let offset = overrideOffset ?? visible.minY
        guard ActivityFeedWindow.shouldLoad(
            offset: offset, viewport: viewport,
            eligibility: ActivityFeedEligibility(positioned: positioned, restoring: false, visible: model.visible,
                                                 loading: model.history.isLoading, error: model.history.error)
        ), rejectedIDs != model.allRowIDs else { return false }
        guard let boundary = ActivityFeedWindow.olderBoundary(ids: model.allRowIDs,
                                                              retainedID: state.retainedFirstID) else {
            guard model.history.hasMore,
                  shortFill.consume(content: table.bounds.height, viewport: viewport) else { return false }
            requestPage(retry: false)
            return true
        }
        guard shortFill.consume(content: table.bounds.height, viewport: viewport) else { return false }
        state.retainedFirstID = boundary
        return true
    }

    /// Resumes what an incoherent native window held, in the order a coherent reader would
    /// have seen it: the held paging intent first — evaluated at the offset it reached,
    /// revealing retained rows and then opening the one bounded request it was about to make —
    /// then the held reading, restored in one owned write. Neither ever applies against a
    /// missing document, and both clear together.
    func resumeHeldReading() {
        let capture = pendingNativeCapture
        let heldOffset = heldPagingOffset
        pendingNativeCapture = nil
        heldPagingOffset = nil
        if let heldOffset {
            while pendingPage == nil, maybeLoadOlder(at: heldOffset) {}
        }
        if let capture { restore(capture) }
    }

    func requestPage(retry: Bool) {
        guard let model, pendingPage == nil, model.visible, !model.history.isLoading,
              retry || model.history.error == nil, let onLoadMore = actions.onLoadMore else { return }
        if retry { rejectedIDs = nil }
        let requested = model.allRowIDs
        guard onLoadMore() else {
            rejectedIDs = requested
            return
        }
        pendingPage = ActivityFeedNativePendingPage(requestedIDs: requested, history: model.history,
                                                    paginationRevision: model.paginationRevision)
        pendingPageObservedLoading = false
        if !reconciling { commitPendingHeader() }
    }

    /// Settles the pending older page before the reconcile transaction builds its entries, so
    /// a committed request never leaves a stale loading header. Committed rows also move the
    /// retained boundary to the newest first row — the reading that is current immediately
    /// before this commit installs — revealing the published older rows instead of letting the
    /// latest-page fallback drop them.
    func resolvePendingPage(model: ActivityFeedNativeModel, state: ParallelColumnUIState) {
        guard let pending = pendingPage else { return }
        if model.history.isLoading { pendingPageObservedLoading = true }
        guard let commit = pending.commit(by: model, observedLoading: pendingPageObservedLoading) else { return }
        pendingPage = nil
        pendingPageObservedLoading = false
        guard case .rows = commit, let first = model.allRowIDs.first,
              first != pending.requestedIDs.first else { return }
        state.retainedFirstID = first
    }

    // MARK: Hosted heights

    /// A hosted root's own height report — local SwiftUI state (a tool row's expanded toggle)
    /// can change a row's height with the model unchanged. Reports are coalesced per entry and
    /// applied in one bounded geometry transaction from a queued main-actor callback, never
    /// from inside the layout pass that produced them.
    func noteHostedHeight(_ height: CGFloat, id: String, revision: Int) {
        guard height.isFinite, height >= 0 else { return }
        pendingHostedHeights[id] = ActivityFeedNativeHostedHeightReport(
            cell: cells[id], height: height, revision: revision)
        queueHostedHeightFlush()
    }

    func queueHostedHeightFlush() {
        guard !hostedHeightFlushQueued else { return }
        hostedHeightFlushQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            hostedHeightFlushQueued = false
            flushHostedHeights()
        }
    }

    /// Applies the coalesced hosted-height reports in one transaction: update the affected
    /// heights, note them, then exactly one owned write — the live bottom while following, the
    /// captured reading while paused. No cell is rewritten, so hosted selection, contextual
    /// menus and accessibility are preserved.
    func flushHostedHeights() {
        guard !reconciling, !pendingHostedHeights.isEmpty, let table else { return }
        let pending = pendingHostedHeights
        pendingHostedHeights.removeAll()
        var indexes = IndexSet()
        for (id, report) in pending {
            guard let cell = report.cell, cell.window != nil, cells[id] === cell,
                  let index = entries.firstIndex(where: { $0.id == id }),
                  boxes.indices.contains(index), boxes[index].revision == report.revision,
                  let retained = boxes[index].height,
                  abs(report.height - retained) > 0.5 else { continue }
            boxes[index].height = report.height
            indexes.insert(index)
        }
        guard !indexes.isEmpty else { return }
        let following = state?.followLive.isFollowing ?? false
        let captured = positioned && !following ? latestReading() : nil
        reconciling = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(PbRadius.Metrics.zero)
            table.noteHeightOfRows(withIndexesChanged: indexes)
        }
        layoutNow()
        reconciling = false
        if following {
            writeBottom()
        } else if let captured {
            restore(captured)
        }
        publishPosition()
        if !pendingHostedHeights.isEmpty { queueHostedHeightFlush() }
    }
}
