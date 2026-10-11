import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - Native selection and geometry

extension SidebarNativeList.Coordinator {
    func synchronizeSelection() {
        guard let outline else { return }
        let indexes = selection.flatMap { destinationIndexes[$0] } ?? []
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
        guard let input, let appliedInput,
              input.historyRevision == appliedInput.historyRevision, input.historyToken == appliedInput.historyToken,
              let sentinel = indexesByID[.init(logicalID: "history:sentinel")],
              scroll.contentView.bounds.height > 0 else { return }
        let rect = outline.rect(ofRow: sentinel)
        let viewport = outline.convert(scroll.contentView.bounds, from: scroll.contentView)
        let visible = rect.maxY >= viewport.minY && rect.minY <= viewport.maxY
        let publication = SidebarNativeHistoryPublication(visible: visible, revision: input.historyRevision, token: input.historyToken)
        guard publication != historyPublication else { return }
        historyPublication = publication
        actions.history(visible, input.historyRevision)
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
