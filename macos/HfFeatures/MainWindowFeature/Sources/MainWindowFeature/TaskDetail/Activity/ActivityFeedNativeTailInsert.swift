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
        let surviving = Set(next.map(\.id))
        if surviving.contains(current.id) { return current }
        guard let table, let scroll, let first = firstRowIndex, let last = lastRowIndex else { return nil }
        let visible = scroll.documentVisibleRect
        for rowsOnly in [true, false] {
            var fallback: ActivityFeedNativeReadingCapture?
            for index in first ... last {
                if rowsOnly, !entries[index].isRow { continue }
                guard let id = entries[index].anchorID, surviving.contains(id) else { continue }
                let rect = table.rect(ofRow: index)
                let capture = ActivityFeedNativeReadingCapture(id: id, relativeOffset: rect.minY - visible.minY)
                if rect.maxY > visible.minY, rect.minY < visible.maxY { return capture }
                fallback = fallback ?? capture
            }
            if let fallback { return fallback }
        }
        return nil
    }
}

private extension ActivityFeedNativeEntry {
    var isRow: Bool {
        if case .row = self { true } else { false }
    }
}
