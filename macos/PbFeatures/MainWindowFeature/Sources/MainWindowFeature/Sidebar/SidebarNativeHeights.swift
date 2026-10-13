import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - Native occupied and natural heights

extension SidebarNativeList.Coordinator {
    func invalidateEnvironmentHeights() {
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: true) }
        for box in boxes {
            box.measurementKey = nil
            box.naturalHeight = nil
            box.fittingHeight = nil
            if !ownsReportedHeight(box) { box.height = nil }
            refresh(box)
        }
        if let outline {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TimeInterval(PbRadius.Metrics.zero)
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(boxes.indices))
            }
        }
    }

    func refresh(_ box: SidebarNativeItemBox) {
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: true) }
        guard let cell = cells[box.entry.displayID] else { box.height = nil; return }
        box.reportGeneration += 1
        let reportGeneration = box.reportGeneration
        rootWriteCount += 1
        cell.configure(entry: box.entry, actions: actions, selected: box.entry.destination == selection,
                       animate: cell.animate, environment: environment,
                       onHeight: { [weak self, weak box, weak cell] height in
                           guard let self, let box, let cell else { return }
                           recordHostedHeight(height, box: box, cell: cell, generation: reportGeneration)
                       })
        guard !ownsReportedHeight(box) else { return }
        let width = cell.host?.frame.width ?? availableWidth
        if let height = cell.measure(width: width) {
            box.fittingHeight = height
            recordHeight(height, box: box)
        }
    }

    var availableWidth: CGFloat { max(0, outline?.tableColumns.first?.width ?? 0) }

    func ownsReportedHeight(_ box: SidebarNativeItemBox) -> Bool {
        guard case .item = box.entry.content,
              !PbMotion.reduceMotion(override: environment.pbReduceMotionOverride, system: environment.accessibilityReduceMotion),
              let cell = box.reportingCell, cell.window != nil else { return false }
        return cells[box.entry.displayID] === cell
    }

    func recordHostedHeight(_ height: CGFloat, box: SidebarNativeItemBox, cell: SidebarNativeCell, generation: Int) {
        guard box.reportGeneration == generation, boxesByID[box.entry.displayID] === box,
              cells[box.entry.displayID] === cell,
              height.isFinite, height >= 0 else { return }
        box.latestHostedReport = height
        if case .item = box.entry.content, cell.window != nil,
           !PbMotion.reduceMotion(override: environment.pbReduceMotionOverride, system: environment.accessibilityReduceMotion) {
            box.reportingCell = cell
            if box.height != height {
                box.pendingHostedHeight = height
                pendingHostedHeights.insert(box.entry.displayID)
            } else {
                box.pendingHostedHeight = nil
                pendingHostedHeights.remove(box.entry.displayID)
            }
            if nativeOperationDepth == 0, !invalidatingHostedHeights { flushHostedHeights() }
            if !pendingHostedHeights.isEmpty { queueGeometry() }
            return
        }
        recordHeight(height, box: box)
    }

    func beginNativeOperation() { nativeOperationDepth += 1 }

    func endNativeOperation(flushHostedHeights: Bool) {
        nativeOperationDepth -= 1
        guard nativeOperationDepth == 0 else { return }
        if flushHostedHeights { self.flushHostedHeights() }
        if !pendingHostedHeights.isEmpty { queueGeometry() }
        // Re-arm deferred prominence delivery by enqueueing only — this boundary still sits
        // inside a native layout pass, so it must never flush the refresh synchronously.
        if !pendingProminenceRefreshes.isEmpty { queueProminenceDelivery() }
    }

    /// One batch at a safe native boundary. Reentrant reports wait for existing queued delivery.
    func flushHostedHeights() {
        guard nativeOperationDepth == 0, !invalidatingHostedHeights,
              !pendingHostedHeights.isEmpty, let outline else { return }
        let pending = pendingHostedHeights
        pendingHostedHeights.removeAll()
        var indexes = IndexSet()
        for id in pending {
            guard let index = indexesByID[id], let box = boxesByID[id] else { continue }
            guard ownsReportedHeight(box), let height = box.pendingHostedHeight else { continue }
            box.pendingHostedHeight = nil
            if box.height != height {
                box.height = height
                indexes.insert(index)
            }
        }
        guard !indexes.isEmpty else { return }
        invalidatingHostedHeights = true
        beginNativeOperation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(PbRadius.Metrics.zero)
            outline.noteHeightOfRows(withIndexesChanged: indexes)
        }
        endNativeOperation(flushHostedHeights: false)
        invalidatingHostedHeights = false
        if !pendingHostedHeights.isEmpty { queueGeometry() }
    }

    func recordHeight(_ height: CGFloat, box: SidebarNativeItemBox) {
        guard availableWidth > 0, height.isFinite, height >= 0,
              boxesByID[box.entry.displayID] === box, box.height != height else { return }
        box.height = height
        pendingHeights.insert(box.entry.displayID)
        queueGeometry()
    }

    func measureNatural(_ box: SidebarNativeItemBox) -> CGFloat? {
        let width = availableWidth
        guard width > 0, width.isFinite else { return nil }
        let key = SidebarNativeMeasurementKey(entryRevision: box.entryRevision, width: width,
                                               environmentRevision: environmentRevision,
                                               selected: box.entry.destination == selection,
                                                   emphasized: observedProminence(box))
        if box.measurementKey == key, let height = box.naturalHeight { return height }
        measurementCount += 1
        let started = Date.timeIntervalSinceReferenceDate
        defer { naturalMeasurementSeconds += Date.timeIntervalSinceReferenceDate - started }
        let root = SidebarNativeRow(entry: box.entry, actions: actions, selected: key.selected, animate: false,
                                    environment: environment, increasedProminence: key.emphasized,
                                    availableWidth: width, occupiedHeight: { _ in }, measurementOnly: true)
        if let measurementHost { measurementHost.rootView = root } else {
            let host = NSHostingView(rootView: root)
            host.sizingOptions = [.intrinsicContentSize]
            host.setAccessibilityElement(false)
            measurementHost = host
        }
        guard let host = measurementHost else { return nil }
        host.frame.size.width = width
        let height = host.fittingSize.height
        guard height.isFinite, height >= 0 else { return nil }
        box.measurementKey = key
        box.naturalHeight = height
        return height
    }

    /// AppKit forbids requesting row views inside its height delegate, even without creation.
    /// Before a cell is associated, prominence is standard and provisional; current variants use
    /// it only for ink. Realization and backgroundStyle callbacks invalidate a differing cache.
    func observedProminence(_ box: SidebarNativeItemBox) -> Bool {
        if let cell = cells[box.entry.displayID], cell.association === box {
            return cell.backgroundStyle == .emphasized
        }
        return false
    }

    func invalidateNaturalProminence(_ box: SidebarNativeItemBox) {
        guard let key = box.measurementKey, key.emphasized != observedProminence(box) else { return }
        box.measurementKey = nil
        box.naturalHeight = nil
        box.fittingHeight = nil
        if !ownsReportedHeight(box) {
            box.height = nil
            pendingHeights.insert(box.entry.displayID)
            queueGeometry()
        }
    }

    /// Queues the hosting-root refresh a prominence change requires. A `backgroundStyle`
    /// callback can fire while AppKit owns a native operation — inside `layout()` — where
    /// rewriting the cell's SwiftUI root synchronously crosses the native operation boundary, so only
    /// cache invalidation (`invalidateNaturalProminence`) runs inline; the root refresh waits
    /// for a queued main-actor callback. Coalesced per display ID and bound to the association
    /// token captured when queued, so a reused, detached or re-associated cell never receives it.
    func queueProminenceRefresh(_ box: SidebarNativeItemBox, cell: SidebarNativeCell, associationToken: UUID) {
        pendingProminenceRefreshes[box.entry.displayID] = SidebarNativePendingProminence(
            box: box, cell: cell, associationToken: associationToken
        )
        queueProminenceDelivery()
    }

    func queueProminenceDelivery() {
        guard !prominenceRefreshQueued else { return }
        prominenceRefreshQueued = true
        let generation = prominenceDeliveryGeneration
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, generation == prominenceDeliveryGeneration else { return }
            prominenceRefreshQueued = false
            deliverProminenceRefresh(generation: generation)
        }
    }

    /// Delivers deferred prominence refreshes only outside every native operation, from the
    /// queued main-actor callback. A stale generation (a stopped coordinator) or a stale
    /// association token (reuse/detach/re-associate) drops the work — a fresh association
    /// configures its cell itself, so nothing is lost. An in-flight native operation retains
    /// the pending work; the next `endNativeOperation` boundary re-arms delivery by enqueueing
    /// again. Never refreshes synchronously here, and never from a native-operation boundary.
    func deliverProminenceRefresh(generation: Int) {
        guard generation == prominenceDeliveryGeneration, nativeOperationDepth == 0 else { return }
        let pending = pendingProminenceRefreshes
        pendingProminenceRefreshes.removeAll()
        for (id, request) in pending {
            guard let box = request.box, let cell = request.cell,
                  boxesByID[id] === box, cells[id] === cell,
                  box.associationToken == request.associationToken, cell.association === box else { continue }
            refresh(box)
        }
    }

}
