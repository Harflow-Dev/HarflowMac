//
//  ActivityFeedNativeReconcile.swift
//  MainWindowFeature
//
//  The native feed's reconcile transaction: entry installation with height-cache carry-over,
//  pre-measurement against the real column width, cell refresh, the table's data source and
//  delegate, and the reading geometry every restore writes against. One transaction per
//  SwiftUI update; exactly one owned scroll write at its end.
//

import AppKit
import MonitorCore
import PbUI
import SwiftUI

// MARK: - Reading capture

/// One captured reading position: the first visible semantic row and its distance above the
/// viewport top. Held across an incoherent native document and restored in one owned write.
struct ActivityFeedNativeReadingCapture {
    let id: String
    let relativeOffset: CGFloat
}

// MARK: - Reconcile transaction

extension ActivityFeedNativeList.Coordinator {
    func reconcile(environmentHeightsInvalidated: Bool, rootsNeedRefresh: Bool) {
        guard !reconciling, let model, let state, let table else { return }
        reconciling = true
        defer { reconciling = false }

        // What an incoherent native window held — a detached document's synthetic moves —
        // resumes first: its paging intent at the offset it reached, then its reading.
        resumeHeldReading()
        // The pending page settles before this transaction builds its entries, so a committed
        // request never leaves a stale loading header behind, and the retained boundary reveals
        // the published older rows in this same install.
        resolvePendingPage(model: model, state: state)
        transferRegroupedState(state: state, model: model)
        let following = state.followLive.isFollowing
        let header = ActivityFeedNativeEntries.resolveHeader(
            history: model.history,
            showsBeginning: ActivityFeedNativeEntries.showsBeginning(
                allRowIDs: model.allRowIDs, shownRows: model.shownRows,
                retainedFirstID: state.retainedFirstID, history: model.history),
            pendingPage: pendingPage != nil
        )
        let next = ActivityFeedNativeEntries.build(model: model, header: header, following: following,
                                                    mountedIDs: mountedIDs)
        let plan = ActivityFeedNativePlan.plan(previous: entries, next: next)
        apply(plan: plan, next: next, following: following,
              environmentHeightsInvalidated: environmentHeightsInvalidated, rootsNeedRefresh: rootsNeedRefresh)
        if model.shownRows.isEmpty {
            if firstRowIndex == nil { state.anchor = nil }
            if state.retainedFirstID != nil { state.retainedFirstID = nil }
        }
        maybePerformInitialPositioning()
        publishPosition()
        maybeLoadOlder()
        commitPendingHeader()
    }

    /// An accepted request owns its loading header immediately, even when the caller has
    /// not published a loading snapshot. Inside reconcile this finishes the current transaction;
    /// outside it this is one controlled native geometry transaction preserving the latest reading.
    func commitPendingHeader() {
        guard pendingPage != nil, let model, let state else { return }
        if case .header(.loading) = entries.first { return }
        let wasReconciling = reconciling
        // Direct request callbacks can arrive before a bounds notification publishes the
        // current reading. A header-only transaction captures that coherent native reading;
        // a reconcile already owns any transferred regroup anchor and keeps it intact.
        if !wasReconciling { publishPosition() }
        reconciling = true
        defer { reconciling = wasReconciling }
        let next = ActivityFeedNativeEntries.build(model: model, header: .loading,
                                                   following: state.followLive.isFollowing,
                                                   mountedIDs: mountedIDs)
        apply(plan: ActivityFeedNativePlan.plan(previous: entries, next: next), next: next,
              following: state.followLive.isFollowing,
              environmentHeightsInvalidated: false, rootsNeedRefresh: false)
        publishPosition()
    }

    /// Applies one reconcile plan to the table: an unchanged id set refreshes content and
    /// heights, a pure append notes the new row count, and a structural change reloads — each
    /// with at most one owned scroll write at its end.
    private func apply(plan: ActivityFeedNativePlan, next: [ActivityFeedNativeEntry], following: Bool,
                       environmentHeightsInvalidated: Bool, rootsNeedRefresh: Bool) {
        guard let table else { return }
        switch plan {
        case .unchanged:
            // Same entry ids: only content can change — and a same-ID change above the
            // viewport shifts the rows below it, so every paused transaction captures the
            // reading first, not only an environment refresh.
            applyUnchanged(next: next, following: following,
                           environmentHeightsInvalidated: environmentHeightsInvalidated,
                           rootsNeedRefresh: rootsNeedRefresh)
        case .append:
            let changedIDs = installEntries(next)
            let changed = measureChangedHeights()
            guard positioned, table.window != nil else { return }
            table.noteNumberOfRowsChanged()
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
            refreshVisibleCells(changedIDs: changedIDs, refreshAll: rootsNeedRefresh)
            layoutNow()
            if following { writeBottom() }
        case .structural:
            let captured = positioned && !following ? structuralReading(next: next) : nil
            _ = installEntries(next)
            _ = measureChangedHeights()
            guard table.window != nil else { return }
            table.reloadData()
            layoutNow()
            if positioned, following {
                writeBottom()
            } else if positioned, let captured {
                restore(captured)
            }
        }
    }

    /// The unchanged plan: refresh the affected cells and heights, and keep the bottom pinned
    /// when a live-followed row or tail grows, or the captured reading when the reader paused.
    private func applyUnchanged(next: [ActivityFeedNativeEntry], following: Bool,
                                environmentHeightsInvalidated: Bool, rootsNeedRefresh: Bool) {
        guard let table else { return }
        let captured = positioned && !following ? latestReading() : nil
        let changedIDs = installEntries(next)
        let changed = measureChangedHeights()
        guard positioned, table.window != nil else { return }
        refreshVisibleCells(changedIDs: changedIDs, refreshAll: rootsNeedRefresh)
        let heightsToNote = environmentHeightsInvalidated ? IndexSet(boxes.indices) : changed
        guard !heightsToNote.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: heightsToNote)
        layoutNow()
        if following {
            writeBottom()
        } else if let captured {
            restore(captured)
        }
    }

    /// Builds the boxes for the next entries, reusing a retained row's box (and its cached
    /// height) when its render inputs are unchanged. A changed same-ID entry gets a fresh box
    /// that carries its predecessor's cached height — the comparison value that decides whether
    /// the row's height actually changed; without it, a disclosure or a growing row would keep
    /// displaying in its old slot. Returns the ids whose render inputs changed.
    @discardableResult
    func installEntries(_ next: [ActivityFeedNativeEntry]) -> Set<String> {
        var nextBoxes: [ActivityFeedNativeItemBox] = []
        var changedIDs: Set<String> = []
        nextBoxes.reserveCapacity(next.count)
        var boxesByID: [String: ActivityFeedNativeItemBox] = [:]
        boxesByID.reserveCapacity(boxes.count)
        for box in boxes { boxesByID[box.entry.id] = box }
        for entry in next {
            if let retained = boxesByID[entry.id], retained.entry == entry {
                nextBoxes.append(retained)
                continue
            }
            changedIDs.insert(entry.id)
            let previous = boxesByID[entry.id]
            let box = ActivityFeedNativeItemBox(entry: entry, revision: (previous?.revision ?? -1) + 1)
            box.height = previous?.height
            nextBoxes.append(box)
            boxesByID[entry.id] = box
        }
        entries = next
        boxes = nextBoxes
        indexRowEntries()
        let liveIDs = Set(next.map(\.id))
        for (id, cell) in cells where !liveIDs.contains(id) {
            cell.onMounted = nil
            cells.removeValue(forKey: id)
        }
        return changedIDs
    }

    /// Pre-measures every entry whose box is new or whose cache was invalidated, before the
    /// table updates, so the delegate's height requests are all cache hits. Reports the indexes
    /// of retained rows whose measured height changed — a same-ID row whose content changed
    /// compares against the height its superseded box cached, so a real change is never missed.
    func measureChangedHeights() -> IndexSet {
        var changed = IndexSet()
        for (index, box) in boxes.enumerated() {
            let retained = box.height
            guard let height = height(of: box), let retained, abs(height - retained) > 0.5 else { continue }
            changed.insert(index)
        }
        return changed
    }

    func invalidateAllHeights() {
        for box in boxes { box.measurementKey = nil }
    }

    /// Reconfigures the realized cells whose entries changed — or every visible cell when the
    /// supported public inherited environment or the root inputs changed, so a non-height style change
    /// or a padding change reaches every displayed root, never only re-measured rows.
    func refreshVisibleCells(changedIDs: Set<String>, refreshAll: Bool) {
        guard let table, table.window != nil, refreshAll || !changedIDs.isEmpty else { return }
        let visible = table.visibleRect
        guard !visible.isEmpty else { return }
        for index in boxes.indices {
            let box = boxes[index]
            guard refreshAll || changedIDs.contains(box.entry.id) else { continue }
            let rect = table.rect(ofRow: index)
            guard rect.intersects(visible) else { continue }
            guard let cell = cells[box.entry.id], cell.entryID == box.entry.id else { continue }
            cell.configure(root: root(for: box, reporting: true), id: box.entry.id)
        }
    }

    /// Transfers the anchor, the retained boundary and disclosure state across regrouping.
    /// The boundary and disclosure transfer run independently of the anchor: a regroup can
    /// consume the retained boundary's row or an expanded group while the anchor row survives.
    func transferRegroupedState(state: ParallelColumnUIState, model: ActivityFeedNativeModel) {
        guard let previous = previousModel else { return }
        var retainedFirstID = state.retainedFirstID
        var expandedGroups = state.expandedGroups
        if let anchor = state.anchor,
           let replacement = ActivityFeedNativeRegroup.transfer(
               anchor: anchor, old: previous.shownRows, next: model.shownRows,
               retainedFirstID: &retainedFirstID, expandedGroups: &expandedGroups
           ) {
            state.anchor = replacement
        }
        ActivityFeedNativeRegroup.transferBoundary(
            retainedFirstID: &retainedFirstID, old: previous.shownRows, next: model.shownRows)
        ActivityFeedNativeRegroup.transferDisclosures(
            expandedGroups: &expandedGroups, old: previous.shownRows, next: model.shownRows)
        if state.retainedFirstID != retainedFirstID { state.retainedFirstID = retainedFirstID }
        if state.expandedGroups != expandedGroups { state.expandedGroups = expandedGroups }
    }

    // MARK: Data source and delegate

    func numberOfRows(in _: NSTableView) -> Int { boxes.count }

    func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard boxes.indices.contains(row) else { return PbRadius.Metrics.hairlineStroke }
        return max(PbRadius.Metrics.hairlineStroke,
                   height(of: boxes[row]) ?? PbRadius.Metrics.hairlineStroke)
    }

    func tableView(_ tableView: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard boxes.indices.contains(row) else { return nil }
        let box = boxes[row]
        let identifier = NSUserInterfaceItemIdentifier("ActivityFeedNativeCell")
        let cell = cells[box.entry.id] ?? {
            let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? ActivityFeedNativeCell
                ?? ActivityFeedNativeCell()
            reused.identifier = identifier
            return reused
        }()
        if cell.entryID != box.entry.id, let previous = cell.entryID, cells[previous] === cell {
            cells.removeValue(forKey: previous)
        }
        cells[box.entry.id] = cell
        cell.onMounted = { [weak self, weak cell] in
            guard let self, let cell, let id = cell.entryID else { return }
            mountedIDs.insert(id)
        }
        cell.configure(root: root(for: box, reporting: true), id: box.entry.id)
        cell.frame.size.width = currentWidth
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow _: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("ActivityFeedNativeRowView")
        let row = tableView.makeView(withIdentifier: identifier, owner: self) as? ActivityFeedNativeRowView
            ?? ActivityFeedNativeRowView()
        row.identifier = identifier
        return row
    }

    func tableView(_: NSTableView, shouldSelectRow _: Int) -> Bool { false }

    // MARK: Measurement

    /// The hosting width of every row root — measured and displayed alike: the table column's
    /// actual cell width, which the frame transaction keeps equal to the clip width minus the
    /// measured intercell spacing. Before a frame transaction has run, the same value is
    /// derived from the live clip, so measurement starts as soon as the clip is laid out —
    /// measuring at the raw clip width instead would wrap text wider than any real cell renders
    /// and break height parity for long content.
    var currentWidth: CGFloat {
        if width > 0, let column = table?.tableColumns.first { return max(0, column.width) }
        let clip = scroll?.contentView.bounds.width ?? 0
        return max(0, clip - ActivityFeedNativeListMetrics.horizontalIntercellSpacing)
    }

    /// Keeps the real column — the width the table lays cells out at — equal to the hosting
    /// width derived from the clip, so measurement and display share one actual column width.
    func applyColumnWidth(_ clipWidth: CGFloat) {
        guard let column = table?.tableColumns.first else { return }
        let hosting = max(0, clipWidth - ActivityFeedNativeListMetrics.horizontalIntercellSpacing)
        if abs(column.width - hosting) > 0.5 { column.width = hosting }
    }

    /// The cached height for a box, measuring it once per (revision, column width, environment,
    /// root inputs) key. The measurement host renders the same root, at the same pinned width,
    /// with the same supported public inherited environment as the displayed cell, and never carries a
    /// height report.
    func height(of box: ActivityFeedNativeItemBox) -> CGFloat? {
        let width = currentWidth
        let key = ActivityFeedNativeMeasurementKey(revision: box.revision, width: width,
                                                    environmentRevision: environmentRevision,
                                                    rootInputsRevision: rootInputsRevision)
        if box.measurementKey == key, let height = box.height { return height }
        guard width > 0, let height = measure(box, width: width) else { return box.height }
        box.measurementKey = key
        box.height = height
        return height
    }

    func measure(_ box: ActivityFeedNativeItemBox, width: CGFloat) -> CGFloat? {
        let root = root(for: box)
        // A fresh identity prevents a previous row's SwiftUI state and deferred intrinsic
        // size from becoming the next row's cached geometry.
        let host = NSHostingView(rootView: root)
        host.sizingOptions = [.intrinsicContentSize]
        host.setAccessibilityElement(false)
        host.frame.size.width = width
        let height = host.fittingSize.height
        return height.isFinite && height >= 0 ? height : nil
    }

    /// The one SwiftUI root for a box. A realized cell's root also reports every change of its
    /// own laid-out height, bound to the box's render revision so a superseded box's report can
    /// never overwrite a newer measurement.
    func root(for box: ActivityFeedNativeItemBox, reporting: Bool = false) -> ActivityFeedNativeRowRoot {
        var root = if let model {
            ActivityFeedNativeRowRoot(entry: box.entry, start: model.start,
                                             horizontalPadding: model.horizontalPadding,
                                             showsPromptBubble: model.showsPromptBubble,
                                             environment: environment, actions: actions,
                                             availableWidth: max(0, currentWidth))
        } else {
            ActivityFeedNativeRowRoot(entry: box.entry, start: nil, horizontalPadding: 0,
                                             showsPromptBubble: false, environment: environment,
                                             actions: actions, availableWidth: nil)
        }
        if reporting {
            let id = box.entry.id
            let revision = box.revision
            root.onHostedHeight = { [weak self, weak box] height in
                guard let self, let box, box.entry.id == id else { return }
                noteHostedHeight(height, id: id, revision: revision)
            }
        }
        return root
    }

    func indexRowEntries() {
        firstRowIndex = nil
        lastRowIndex = nil
        for (index, entry) in entries.enumerated() where entry.anchorID != nil {
            if firstRowIndex == nil { firstRowIndex = index }
            lastRowIndex = index
        }
    }

    // MARK: Reading geometry

    /// The reading position a geometry transaction restores: the persisted anchor, which every
    /// observed movement has kept current — the latest reading, never one captured when a
    /// page request was made. Falls back to the live viewport when no reading was published.
    private func structuralReading(next: [ActivityFeedNativeEntry]) -> ActivityFeedNativeReadingCapture? {
        if let anchor = state?.anchor, !entries.contains(where: { $0.id == anchor.id }),
           next.contains(where: { $0.id == anchor.id }) {
            return ActivityFeedNativeReadingCapture(id: anchor.id, relativeOffset: anchor.relativeOffset)
        }
        return latestReading()
    }

    func latestReading() -> ActivityFeedNativeReadingCapture? {
        if let current = captureReading() { return current }
        if let anchor = state?.anchor, entries.contains(where: { $0.id == anchor.id }) {
            return ActivityFeedNativeReadingCapture(id: anchor.id, relativeOffset: anchor.relativeOffset)
        }
        return captureReading()
    }

    /// The first visible semantic row and its distance above the viewport top, read from
    /// the table's live rects before any mutation. A reading is evidence only while its row's
    /// hosted content is realized in its correct semantic slot: geometry from rows the table
    /// has not laid out — a detached document's synthetic moves among them — never overwrites
    /// the durable reading anchor.
    func captureReading() -> ActivityFeedNativeReadingCapture? {
        guard let table, let scroll, scroll.documentView === table, table.window != nil, positioned,
              let first = firstRowIndex, let last = lastRowIndex else { return nil }
        let visible = scroll.documentVisibleRect
        guard visible.height > 0 else { return nil }
        var lower = first
        var upper = last + 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if table.rect(ofRow: middle).maxY <= visible.minY {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower <= last else { return nil }
        let rect = table.rect(ofRow: lower)
        guard rect.minY < visible.maxY, let id = entries[lower].anchorID else { return nil }
        guard isRowContentRealized(index: lower, id: id, rect: rect) else { return nil }
        return ActivityFeedNativeReadingCapture(id: id, relativeOffset: rect.minY - visible.minY)
    }

    /// Whether a row's hosted cell is realized in its correct semantic slot with hosted
    /// content — the same evidence contract a mounted measurement must satisfy.
    private func isRowContentRealized(index: Int, id: String, rect: CGRect) -> Bool {
        guard let table, let cell = cells[id], cell.entryID == id, let host = cell.host,
              cell.window != nil, host.window === table.window,
              host.bounds.width > 0, host.bounds.height > 0 else { return false }
        let frame = cell.convert(cell.bounds, to: table)
        return frame.minY >= rect.minY - 1 && frame.maxY <= rect.maxY + 1
            && frame.minX >= rect.minX - 1 && frame.maxX <= rect.maxX + 1
    }

    /// Restores a captured position after a structural change: one owned write, clamped so
    /// a shrunken anchor row still keeps positive content visible.
    func restore(_ captured: ActivityFeedNativeReadingCapture) {
        guard let table else { return }
        guard let index = entries.firstIndex(where: { $0.id == captured.id }) else { return }
        let rect = table.rect(ofRow: index)
        let target = max(0, rect.minY - max(captured.relativeOffset, -max(0, rect.height - 1)))
        writeOffset(target)
    }

    /// Restores the persisted anchor (remount, or a measured viewport resize).
    func restoreAnchor(_ anchor: ParallelVerticalAnchor) {
        guard let table, let model else { return }
        let shownIDs = model.shownRows.map(\.id)
        let id = entries.contains(where: { $0.anchorID == anchor.id })
            ? anchor.id : anchor.resolvedID(in: shownIDs)
        guard let id, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let rect = table.rect(ofRow: index)
        writeOffset(ActivityFeedNativeReading.restoredOffset(anchor: anchor, resolvedIndex: index, rowRect: rect))
    }

    func firstVisibleAnchor() -> ParallelVerticalAnchor? {
        guard let first = firstRowIndex else { return nil }
        guard let capture = captureReading(),
              let index = entries.firstIndex(where: { $0.id == capture.id }), index >= first else { return nil }
        return ParallelVerticalAnchor(id: capture.id, index: index - first, relativeOffset: capture.relativeOffset)
    }

    // MARK: Owned scroll writes

    func writeOffset(_ target: CGFloat) {
        guard let scroll, let table else { return }
        let maxOffset = max(0, table.bounds.height - scroll.contentView.bounds.height)
        let clamped = min(max(0, target), maxOffset)
        guard abs(clamped - scroll.documentVisibleRect.minY) > 0.5 else { return }
        programmaticScrollDepth += 1
        scroll.contentView.scroll(to: CGPoint(x: 0, y: clamped))
        scroll.reflectScrolledClipView(scroll.contentView)
        lastObservedMinY = scroll.documentVisibleRect.minY
        programmaticScrollDepth -= 1
        publishPosition()
    }

    func writeBottom() {
        guard let scroll, let table else { return }
        writeOffset(max(0, table.bounds.height - scroll.contentView.bounds.height))
    }

    func layoutNow() {
        scroll?.layoutSubtreeIfNeeded()
        table?.layoutSubtreeIfNeeded()
    }

    // MARK: Position publication

    func publishPosition() {
        guard let state, let scroll else { return }
        state.scrollOffset = scroll.documentVisibleRect.minY
        if let anchor = firstVisibleAnchor() {
            state.anchor = anchor
        } else if firstRowIndex == nil {
            state.anchor = nil
        }
        state.viewportPositioned = positioned
    }

    // MARK: Initial positioning

    func schedulePositioningCheck() {
        guard !positioningCheckQueued else { return }
        positioningCheckQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            positioningCheckQueued = false
            maybePerformInitialPositioning()
            publishPosition()
            maybeLoadOlder()
        }
    }

    func maybePerformInitialPositioning() {
        guard needsInitialPosition, let scroll, let table, let state else { return }
        let viewport = scroll.contentView.bounds.height
        guard viewport > 0, currentWidth > 0, table.window != nil, !boxes.isEmpty else { return }
        needsInitialPosition = false
        let previouslyReconciling = reconciling
        reconciling = true
        defer { reconciling = previouslyReconciling }
        width = scroll.contentView.bounds.width
        applyColumnWidth(width)
        _ = measureChangedHeights()
        table.reloadData()
        layoutNow()
        if state.followLive.isFollowing {
            writeBottom()
        } else if let anchor = state.anchor {
            restoreAnchor(anchor)
        } else {
            writeOffset(state.scrollOffset)
        }
        positioned = true
        lastObservedMinY = scroll.documentVisibleRect.minY
    }
}
