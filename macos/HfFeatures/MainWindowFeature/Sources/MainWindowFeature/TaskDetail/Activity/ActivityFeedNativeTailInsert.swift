//
//  ActivityFeedNativeTailInsert.swift
//  MainWindowFeature
//
//  The live-append transaction: the batched removal of a leading run and insertion of new rows
//  ahead of the trailing entries, with the reading kept across the slide.
//

import AppKit
import MonitorCore

// MARK: - Tail insert

extension ActivityFeedNativeList.Coordinator {
    /// Live append and window slide on a positioned table: the leading run leaves and the new
    /// rows arrive ahead of the trailing entries in one batched update with no row animation,
    /// then the retained rows whose height changed (the new first row's spacing included) are
    /// noted against their post-update indexes. A following reader writes the bottom; a paused
    /// reader keeps the captured row in place when anything was removed or resized, and
    /// otherwise no scroll write happens.
    func applyTailInsert(next: [ActivityFeedNativeEntry], following: Bool, removeLeading: Int,
                         insertAt: Int, count: Int) {
        guard let table else { return }
        let captured = following ? nil : tailInsertReading(next: next)
        let changedIDs = installEntries(next)
        let changed = measureChangedHeights()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            table.beginUpdates()
            if removeLeading > 0 { table.removeRows(at: IndexSet(0 ..< removeLeading), withAnimation: []) }
            table.insertRows(at: IndexSet(insertAt ..< insertAt + count), withAnimation: [])
            table.endUpdates()
            if !changed.isEmpty { table.noteHeightOfRows(withIndexesChanged: changed) }
        }
        layoutNow()
        if following {
            writeBottom()
        } else if let captured {
            // Rows inserted ahead of a reading that sits in the trailing entries push it down.
            let belowInsert = entries.firstIndex { $0.id == captured.id }.map { $0 >= insertAt + count } ?? false
            if removeLeading > 0 || !changed.isEmpty || belowInsert { restore(captured) }
        }
        refreshRealizedCells(changedIDs: changedIDs)
    }

    /// Reconfigures every realized cell whose entry changed, wherever it sits: the scroll write
    /// has moved the viewport, so a rect test against the old offset could skip a cell that is
    /// about to be shown.
    private func refreshRealizedCells(changedIDs: Set<String>) {
        guard !changedIDs.isEmpty else { return }
        for box in boxes where changedIDs.contains(box.entry.id) {
            guard let cell = cells[box.entry.id], cell.entryID == box.entry.id else { continue }
            rootRefreshCount += 1
            cell.configure(root: root(for: box, reporting: true), id: box.entry.id)
        }
        layoutNow()
    }

    /// The reading a tail insert keeps. When the captured row leaves with the removed leading
    /// run, the first visible row that survives in `next` stands in for it, else the first
    /// surviving row: `restore` writes nothing for a row it cannot find. Only rows qualify; the
    /// tail and approvals are a fallback for a list in which no row survives.
    func tailInsertReading(next: [ActivityFeedNativeEntry]) -> ActivityFeedNativeReadingCapture? {
        guard let current = latestReading() else { return nil }
        return survivingReading(current, next: next)
    }

    /// The reading a structural reload keeps. A surviving captured row is returned as is. Otherwise
    /// `ActivityFeedNativeReading.structuralFallback` picks, in order, the first visible surviving row (held at its
    /// old on-screen offset, so a regrouped card that replaces the anchor moves nothing the reader can see), then the
    /// first visible surviving tail or approval, then the nearest preceding surviving row (else the nearest following
    /// one) with its offset recomputed from its old rect: the case of a removed entry taller than the viewport.
    /// Scope: this is the removed-anchor fallback only. When `transferRegroupedState` hands the persisted anchor to a
    /// replacement that shares members with the old row, `structuralReading` pins that replacement through its
    /// persisted-anchor branch before this runs; that logical-anchor behaviour is unchanged.
    func structuralSurvivingReading(_ current: ActivityFeedNativeReadingCapture,
                                    next: [ActivityFeedNativeEntry]) -> ActivityFeedNativeReadingCapture? {
        let surviving = Set(next.map(\.id))
        if surviving.contains(current.id) { return current }
        guard let scroll, let entries = fallbackEntries() else { return nil }
        return ActivityFeedNativeReading
            .structuralFallback(entries: entries, visible: scroll.documentVisibleRect, surviving: surviving,
                                captured: current.id)
            .map { ActivityFeedNativeReadingCapture(id: $0.id, relativeOffset: $0.relativeOffset) }
    }

    /// The anchoring entries of the current layout in list order, with their rects, for the fallback scans.
    private func fallbackEntries() -> [ActivityFeedNativeReading.FallbackEntry]? {
        guard let table, let first = firstRowIndex, let last = lastRowIndex else { return nil }
        return (first ... last).map { index in
            ActivityFeedNativeReading.FallbackEntry(id: entries[index].id, anchorID: entries[index].anchorID,
                                                    isRow: entries[index].isRow, rect: table.rect(ofRow: index))
        }
    }

    /// `current` when its entry survives in `next`; otherwise the first visible row that does, else the first
    /// surviving row. Used by the tail insert, where a reading whose entry leaves with the window run lands on the
    /// first surviving row; the structural reload uses `structuralSurvivingReading` instead. The visible-entry scan is
    /// shared with it (`ActivityFeedNativeReading.visibleSurviving`); the first-surviving fallback is this path's own.
    func survivingReading(_ current: ActivityFeedNativeReadingCapture,
                          next: [ActivityFeedNativeEntry]) -> ActivityFeedNativeReadingCapture? {
        let surviving = Set(next.map(\.id))
        if surviving.contains(current.id) { return current }
        guard let scroll, let scanned = fallbackEntries() else { return nil }
        let visible = scroll.documentVisibleRect
        for rowsOnly in [true, false] {
            let result = ActivityFeedNativeReading.visibleSurviving(entries: scanned, visible: visible,
                                                                    surviving: surviving, rowsOnly: rowsOnly)
            if let hit = result.visible ?? result.first {
                return ActivityFeedNativeReadingCapture(id: hit.id, relativeOffset: hit.relativeOffset)
            }
        }
        return nil
    }
}

private extension ActivityFeedNativeEntry {
    var isRow: Bool {
        if case .row = self { true } else { false }
    }
}
