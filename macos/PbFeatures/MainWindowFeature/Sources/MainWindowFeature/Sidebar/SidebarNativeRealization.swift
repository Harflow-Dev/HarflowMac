import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - Native delegate and cell realization

extension SidebarNativeList.Coordinator {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem _: Any?) -> Int { boxes.count }
    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any { boxes[index] }
    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool { false }

    func outlineView(_: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? SidebarNativeItemBox)?.entry.isHeading == true
    }

    func outlineView(_: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? SidebarNativeItemBox)?.entry.destination != nil
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: false) }
        guard let box = item as? SidebarNativeItemBox else { return PbRadius.Metrics.hairlineStroke }
        if box.latestHostedReport != nil, cells[box.entry.displayID] == nil {
            box.height = nil
            box.latestHostedReport = nil
        }
        if let height = box.height { return max(PbRadius.Metrics.hairlineStroke, height) }
        // AppKit requires a positive native slot even while real disclosure content occupies
        // zero. An unavailable width remains pending; the native floor is never measurement.
        guard let measured = measureNatural(box) else { return PbRadius.Metrics.hairlineStroke }
        let reduceMotion = PbMotion.reduceMotion(override: environment.pbReduceMotionOverride, system: environment.accessibilityReduceMotion)
        let occupied = box.entry.isFading && !reduceMotion ? PbRadius.Metrics.zero : measured
        box.fittingHeight = occupied
        box.height = occupied
        return max(PbRadius.Metrics.hairlineStroke, occupied)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor _: NSTableColumn?, item: Any) -> NSView? {
        guard let box = item as? SidebarNativeItemBox else { return nil }
        return cell(for: box, outline: outlineView)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem _: Any) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("SidebarNativeSelection")
        let row = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarNativeSelection
            ?? SidebarNativeSelection()
        row.identifier = identifier
        return row
    }

    func cell(for box: SidebarNativeItemBox, outline: NSOutlineView) -> SidebarNativeCell {
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: false) }
        if let cell = cells[box.entry.displayID], cell.association === box { return cell }
        let identifier = NSUserInterfaceItemIdentifier("SidebarNativeCell")
        let reused = outline.makeView(withIdentifier: identifier, owner: self) as? SidebarNativeCell
        let cell = reused ?? SidebarNativeCell()
        if reused == nil { createdCellCount += 1 }
        cell.identifier = identifier
        if let previous = cell.association { disassociate(previous) }
        cell.association = box
        cell.hasLaidOut = false
        cell.frame.size.width = availableWidth
        cell.animate = !seenIDs.contains(box.entry.id)
        box.reportGeneration += 1
        let reportGeneration = box.reportGeneration
        cells[box.entry.displayID] = cell
        invalidateNaturalProminence(box)
        rootWriteCount += 1
        cell.configure(entry: box.entry, actions: actions, selected: box.entry.destination == selection,
                       animate: cell.animate, environment: environment,
                       onHeight: { [weak self, weak box, weak cell] height in
                           guard let self, let box, let cell else { return }
                           recordHostedHeight(height, box: box, cell: cell, generation: reportGeneration)
                       })
        cell.frame.size.width = availableWidth
        cell.host?.frame.size.width = availableWidth
        cell.onProminence = { [weak self, weak box, weak cell] in
            guard let self, let box, let cell, boxesByID[box.entry.displayID] === box,
                  cells[box.entry.displayID] === cell, cell.association === box else { return }
            invalidateNaturalProminence(box)
            refresh(box)
        }
        cell.onLaidOut = { [weak self, weak box, weak cell] in
            guard let self, let box, let cell, boxesByID[box.entry.displayID] === box,
                  cells[box.entry.displayID] === cell, cell.association === box else { return }
            if !seenIDs.contains(box.entry.id) { pendingMounted.insert(box.entry.displayID) }
            queueGeometry()
        }
        cell.onDetached = { [weak self, weak box, weak cell] in
            guard let self, let box, let cell, boxesByID[box.entry.displayID] === box,
                  cells[box.entry.displayID] === cell, cell.association === box else { return }
            disassociate(box)
        }
        return cell
    }

    func disassociate(_ box: SidebarNativeItemBox) {
        if let cell = cells[box.entry.displayID], cell.association === box {
            cell.association = nil
            cell.onLaidOut = nil
            cell.onProminence = nil
            cell.onDetached = nil
        }
        cells.removeValue(forKey: box.entry.displayID)
        box.reportingCell = nil
        box.reportGeneration += 1
        box.height = nil
        box.pendingHostedHeight = nil
        box.latestHostedReport = nil
        pendingHostedHeights.remove(box.entry.displayID)
        pendingMounted.remove(box.entry.displayID)
    }

}
