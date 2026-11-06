import AppKit
import HfCommon
import HfUI
import SwiftUI

// MARK: - Native selection and geometry

extension SidebarNativeList.Coordinator {
    /// The selection key every native surface shares: native row selection, realized cell
    /// configuration and measurement caching. Every Needs you selection, with or without a
    /// request id, resolves onto the one Needs you row.
    var normalizedSelectionKey: MonitorDestination? {
        guard case .needsYou? = selection else { return selection }
        return .needsYou(itemID: nil)
    }

    /// True when `entry` realizes the current selection. An entry without a destination — a
    /// heading, diagnostic row or the sentinel — never matches, including while no selection exists.
    func isSelected(_ entry: SidebarListEntry) -> Bool {
        guard let destination = entry.destination else { return false }
        return normalizedSelectionKey == destination
    }

    func synchronizeSelection() {
        guard let outline else { return }
        let indexes = normalizedSelectionKey.flatMap { destinationIndexes[$0] } ?? []
        let selectedIDs = Set(indexes.compactMap { boxes.indices.contains($0) ? boxes[$0].entry.displayID : nil })
        let changedIDs = lastHostedSelectedIDs.symmetricDifference(selectedIDs)
        // AppKit may already have changed its indexes before notifying the delegate. Keep
        // hosted presentation identity independently, and publish it before native callbacks.
        lastHostedSelectedIDs = selectedIDs
        let previous = outline.selectedRowIndexes
        if previous != indexes {
            applyingSelection = true
            outline.selectRowIndexes(indexes, byExtendingSelection: false)
            applyingSelection = false
        }
        for id in changedIDs {
            guard let box = boxesByID[id], let cell = cells[id], cell.association === box else { continue }
            refresh(box)
        }
    }

    func refreshProminence() {
        for index in outline?.selectedRowIndexes ?? [] where boxes.indices.contains(index) { refresh(boxes[index]) }
    }

    func queueGeometry() {
        guard !deliveryQueued else { return }
        deliveryQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            deliveryQueued = false
            deliverGeometry()
        }
    }

    func didLayout() {
        guard availableWidth > 0, knownWidth != availableWidth else {
            queueGeometry()
            return
        }
        knownWidth = availableWidth
        guard !widthInvalidationQueued else { return }
        widthInvalidationQueued = true
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let outline else { return }
            widthInvalidationQueued = false
            beginNativeOperation()
            defer { self.endNativeOperation(flushHostedHeights: true) }
            for box in boxes {
                box.fittingHeight = nil
                box.naturalHeight = nil
                if !ownsReportedHeight(box) { box.height = nil }
                if let cell = cells[box.entry.displayID] {
                    cell.frame.size.width = availableWidth
                    cell.host?.setFrameSize(NSSize(width: availableWidth, height: cell.frame.height))
                    refresh(box)
                }
            }
            outline.noteHeightOfRows(withIndexesChanged: IndexSet(boxes.indices))
            queueGeometry()
        }
    }

    func deliverGeometry() {
        guard let outline, let scroll else { return }
        flushHostedHeights()
        // Detached slots restore their static natural estimate at this native-safe queued
        // boundary, before this delivery's sentinel admission reads the gate and the rects.
        restoreDetachedNativeSlots(outline)
        let indexes = IndexSet(pendingHeights.compactMap { indexesByID[$0] })
        pendingHeights.removeAll()
        if !indexes.isEmpty {
            beginNativeOperation()
            outline.noteHeightOfRows(withIndexesChanged: indexes)
            endNativeOperation(flushHostedHeights: false)
        }
        // Mount acknowledgement occurs after a native layout, never in cell construction.
        if !pendingMounted.isEmpty, outline.window != nil {
            let mountedDisplays = pendingMounted.filter { id in
                guard let box = boxesByID[id], let cell = cells[id],
                      cell.association === box, cell.window != nil, cell.frame.width > 0,
                      cell.hasLaidOut, outline.row(forItem: box) >= 0 else { return false }
                return true
            }
            let mounted = Set(mountedDisplays.map(\.logicalID))
            pendingMounted.removeAll()
            seenIDs.formUnion(mounted)
            if !mounted.isEmpty { actions.mounted(mounted) }
        }
        let height = outline.numberOfRows > 0 ? outline.rect(ofRow: outline.numberOfRows - 1).maxY : 0
        if height.isFinite, height >= 0, lastContentHeight != height {
            lastContentHeight = height
            contentHeightChanged?(height)
        }
        guard let input, let appliedInput,
              input.historyRevision == appliedInput.historyRevision, input.historyToken == appliedInput.historyToken,
              let sentinel = indexesByID[.init(logicalID: "history:sentinel")],
              scroll.contentView.bounds.height > 0 else { return }
        let rect = outline.rect(ofRow: sentinel)
        let viewport = outline.convert(scroll.contentView.bounds, from: scroll.contentView)
        let visible = rect.maxY >= viewport.minY && rect.minY <= viewport.maxY
        historyGeometryObserved?(visible)
        // Presentation-settlement gate: a hosted disclosure that has not committed its final
        // logical target atomically with its final height at the native flush boundary keeps
        // every intermediate geometry provisional, so sentinel visibility admits true only
        // from settled layout. A standing admission is actively revoked while any
        // presentation remains unsettled — never merely skipped, which would leave a stale
        // true in force. This is why the arrangement above flushes hosted heights first:
        // admission reads only committed (height, settlement) pairs.
        let publication = SidebarNativeHistoryPublication(
            visible: visible && !hasUnsettledPresentations,
            revision: input.historyRevision, token: input.historyToken
        )
        guard publication != historyPublication else { return }
        historyPublication = publication
        actions.history(publication.visible, input.historyRevision)
    }

    func outlineViewSelectionDidChange(_: Notification) {
        guard !applyingSelection, !applyingStructure, let outline else { return }
        let index = outline.selectedRow
        let destination = boxes.indices.contains(index) ? boxes[index].entry.destination : nil
        selection = destination
        synchronizeSelection()
        actions.select(destination)
    }
}
