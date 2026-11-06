import AppKit
import HfCommon
import HfUI
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
            // An environment change can disable the presentation bridge (Reduce Motion);
            // such rows settle immediately through authoritative geometry.
            if !usesPresentationBridge(box.entry) { retirePresentationSettlement(box) }
            refresh(box)
        }
        if let outline {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = TimeInterval(HfRadius.Metrics.zero)
                outline.noteHeightOfRows(withIndexesChanged: IndexSet(boxes.indices))
            }
        }
    }

    /// The disclosure presentation bridge is active for item rows only, and only while
    /// presentation motion is enabled. Under Reduce Motion every row settles through
    /// authoritative geometry immediately.
    func usesPresentationBridge(_ entry: SidebarListEntry) -> Bool {
        guard case .item = entry.content else { return false }
        return !HfMotion.reduceMotion(override: environment.hfReduceMotionOverride,
                                      system: environment.accessibilityReduceMotion)
    }

    /// Semantic presentation-state summary for fixtures: true while any hosted disclosure has
    /// not committed its settled presentation atomically with its final occupied height. A box
    /// with a recorded pending pair holds the gate even while its committed flag is still true
    /// — until the atomic flush commit, every pending height is provisional — and a detached
    /// box's pending native-slot restoration holds the gate independently of any association.
    var hasUnsettledPresentations: Bool {
        for box in boxes {
            // A detached slot keeps a stale hosted height until the queued boundary restores
            // its static natural estimate; admission waits for that restoration regardless of
            // any cell association.
            if box.pendingNativeSlotRestoration { return true }
            guard !box.presentationSettled || box.pendingHostedHeight != nil else { continue }
            guard usesPresentationBridge(box.entry),
                  let cell = cells[box.entry.displayID], cell.association === box else { continue }
            return true
        }
        return false
    }

    /// Restores the static natural slot estimate for boxes whose reporting association
    /// detached, at the native-safe queued boundary inside geometry delivery — before any
    /// sentinel admission in the same delivery. A detached (scrolled offscreen, reused or
    /// removed-neighbour) box can never re-report, so the natural measurement owns its
    /// geometry again and the pending gate cannot deadlock bounded pagination.
    func restoreDetachedNativeSlots(_ outline: NSOutlineView) {
        guard boxes.contains(where: \.pendingNativeSlotRestoration) else { return }
        var indexes = IndexSet()
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: true) }
        let reduceMotion = HfMotion.reduceMotion(override: environment.hfReduceMotionOverride,
                                                 system: environment.accessibilityReduceMotion)
        for (index, box) in boxes.enumerated() where box.pendingNativeSlotRestoration {
            box.pendingNativeSlotRestoration = false
            guard boxesByID[box.entry.displayID] === box else { continue }
            if !ownsReportedHeight(box), let measured = measureNatural(box) {
                // The same authority `heightOfRowByItem` uses for unre-reported slots.
                let occupied = box.entry.isFading && !reduceMotion ? HfRadius.Metrics.zero : measured
                box.fittingHeight = occupied
                box.height = occupied
                indexes.insert(index)
            }
        }
        guard !indexes.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(HfRadius.Metrics.zero)
            outline.noteHeightOfRows(withIndexesChanged: indexes)
        }
    }

    /// Detach, reuse, structural removal, teardown and a disabled bridge retire a box's
    /// unsettled blocker and let the natural measurement estimate own its geometry again, so a
    /// cell that can never re-report offscreen cannot deadlock bounded pagination.
    func retirePresentationSettlement(_ box: SidebarNativeItemBox) {
        box.presentationSettled = true
        box.pendingHostedSettlement = false
        box.pendingHostedHeight = nil
        pendingHostedHeights.remove(box.entry.displayID)
    }

    func refresh(_ box: SidebarNativeItemBox) {
        beginNativeOperation()
        defer { endNativeOperation(flushHostedHeights: true) }
        guard let cell = cells[box.entry.displayID] else { box.height = nil; return }
        box.reportGeneration += 1
        let reportGeneration = box.reportGeneration
        rootWriteCount += 1
        cell.configure(entry: box.entry, actions: actions, selected: isSelected(box.entry),
                       animate: cell.animate, environment: environment,
                       onHeight: { [weak self, weak box, weak cell] height in
                           guard let self, let box, let cell else { return }
                           recordHostedHeight(height, box: box, cell: cell, generation: reportGeneration)
                       },
                       onPresentation: { [weak self, weak box, weak cell] report in
                           guard let self, let box, let cell else { return }
                           recordHostedPresentation(report, box: box, cell: cell, generation: reportGeneration)
                       },
                       reportAuthority: reportGeneration)
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
              !HfMotion.reduceMotion(override: environment.hfReduceMotionOverride, system: environment.accessibilityReduceMotion),
              let cell = box.reportingCell, cell.window != nil else { return false }
        return cells[box.entry.displayID] === cell
    }

    func recordHostedHeight(_ height: CGFloat, box: SidebarNativeItemBox, cell: SidebarNativeCell, generation: Int) {
        // Geometry-authoritative reports carry the height they occupy; presentation already
        // matches, so they are settled at the height they commit.
        recordHostedPresentation(
            SidebarNativePresentationReport(progress: 1, naturalHeight: height, logicalTarget: 1,
                                            authorityGeneration: generation),
            box: box, cell: cell, generation: generation
        )
    }

    /// Records a combined occupancy/presentation report under one report authority generation.
    /// The reported height and its settlement state commit together at the native flush
    /// boundary, never separately; a current-generation report that repeats the already
    /// committed height still confirms the CURRENT authority, so a root refresh cannot strand
    /// a settled row behind its own registration generation. The report's own authority
    /// generation participates in the guarded identity, so a rebuilt root's re-emitted
    /// endpoint records against the authority the cell captured at configure time.
    func recordHostedPresentation(_ report: SidebarNativePresentationReport,
                                  box: SidebarNativeItemBox, cell: SidebarNativeCell, generation: Int) {
        guard box.reportGeneration == generation, boxesByID[box.entry.displayID] === box,
              cells[box.entry.displayID] === cell, cell.association === box,
              report.authorityGeneration == generation,
              report.occupiedHeight.isFinite, report.occupiedHeight >= 0 else { return }
        box.latestHostedReport = report.occupiedHeight
        box.latestCombinedReport = report
        if case .item = box.entry.content, cell.window != nil, usesPresentationBridge(box.entry) {
            box.reportingCell = cell
            commitHostedPresentation(report, box: box, generation: generation)
            if nativeOperationDepth == 0, !invalidatingHostedHeights { flushHostedHeights() }
            if !pendingHostedHeights.isEmpty { queueGeometry() }
            return
        }
        recordHeight(report.occupiedHeight, box: box)
    }

    private func commitHostedPresentation(_ report: SidebarNativePresentationReport,
                                          box: SidebarNativeItemBox, generation: Int) {
        if box.height != report.occupiedHeight {
            // Height and settlement commit atomically at the native flush boundary; a settled
            // presentation is never admitted ahead of its final committed height.
            box.pendingHostedHeight = report.occupiedHeight
            box.pendingHostedSettlement = report.isSettled
            box.pendingHostedGeneration = generation
            pendingHostedHeights.insert(box.entry.displayID)
        } else {
            // Same height, current authority: confirm settlement directly against the already
            // committed height instead of dropping the report as a no-op.
            box.pendingHostedHeight = nil
            box.pendingHostedSettlement = false
            pendingHostedHeights.remove(box.entry.displayID)
            if box.presentationSettled != report.isSettled {
                box.presentationSettled = report.isSettled
                // pendingHostedHeights is empty here, so no flush will schedule the
                // re-evaluation: the settlement-only transition must queue its own geometry
                // delivery, or the gate change goes unobserved.
                queueGeometry()
            }
        }
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

    /// Validates one pending (height, settlement) pair against its current owner and report
    /// authority. A detached or re-associated owner, or a stale generation (a root refresh
    /// since the report was recorded), never commits: the stale pending fields are cleared,
    /// never retained, so the pending gate cannot hold admission for an authority that will
    /// never commit.
    private func validatedHostedPendingPair(for box: SidebarNativeItemBox) -> (height: CGFloat, settled: Bool)? {
        guard ownsReportedHeight(box), box.pendingHostedGeneration == box.reportGeneration,
              let height = box.pendingHostedHeight else {
            box.pendingHostedHeight = nil
            box.pendingHostedSettlement = false
            return nil
        }
        return (height, box.pendingHostedSettlement)
    }

    /// One batch at a safe native boundary. Reentrant reports wait for existing queued delivery.
    func flushHostedHeights() {
        guard nativeOperationDepth == 0, !invalidatingHostedHeights,
              !pendingHostedHeights.isEmpty, let outline else { return }
        let pending = pendingHostedHeights
        pendingHostedHeights.removeAll()
        var indexes = IndexSet()
        var settlementChanged = false
        for id in pending {
            guard let index = indexesByID[id], let box = boxesByID[id] else { continue }
            guard let pair = validatedHostedPendingPair(for: box) else { continue }
            box.pendingHostedHeight = nil
            box.pendingHostedSettlement = false
            if box.height != pair.height {
                box.height = pair.height
                indexes.insert(index)
            }
            // The height and its settlement state commit together: admission downstream can
            // only observe the pair, never a settled flag without its final height.
            if box.presentationSettled != pair.settled {
                box.presentationSettled = pair.settled
                settlementChanged = true
            }
        }
        // A settlement-only transition (same committed height) still changed the gate; this
        // boundary must never early-return without queuing the admission re-evaluation.
        guard !indexes.isEmpty else {
            if settlementChanged { queueGeometry() }
            return
        }
        invalidatingHostedHeights = true
        beginNativeOperation()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = TimeInterval(HfRadius.Metrics.zero)
            outline.noteHeightOfRows(withIndexesChanged: indexes)
        }
        endNativeOperation(flushHostedHeights: false)
        invalidatingHostedHeights = false
        if !pendingHostedHeights.isEmpty || settlementChanged { queueGeometry() }
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
                                               selected: isSelected(box.entry),
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
