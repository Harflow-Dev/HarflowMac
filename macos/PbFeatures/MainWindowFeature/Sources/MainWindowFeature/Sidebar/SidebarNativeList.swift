import AppKit
import PbCommon
import PbUI
import SwiftUI

// MARK: - SidebarNativeList

/// The native scroll container is the representable endpoint, so ScrollChromeScope owns it directly.
struct SidebarNativeList: NSViewRepresentable {
    let presentation: SidebarListPresentation
    let selection: MonitorDestination?
    let seenIDs: Set<String>
    let configureActions: (SidebarNativeActions) -> Void
    var relay: SidebarNativeTransitionRelay?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.verticalScroller?.controlSize = .small
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        let outline = SidebarOwnedOutlineView()
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .medium
        outline.selectionHighlightStyle = .sourceList
        outline.backgroundColor = .clear
        outline.floatsGroupRows = false
        outline.indentationPerLevel = PbRadius.Metrics.spacing12
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.allowsTypeSelect = true
        outline.intercellSpacing = .zero
        outline.usesAutomaticRowHeights = false
        outline.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        scroll.documentView = outline
        context.coordinator.install(scroll: scroll, outline: outline)
        context.coordinator.bind(relay)
        return scroll
    }

    func updateNSView(_: NSScrollView, context: Context) {
        context.coordinator.bind(relay)
        configureActions(context.coordinator.actions)
        context.coordinator.actions.viewEvent = context.environment.viewEvent
        context.coordinator.update(presentation: presentation, selection: selection,
                                   seenIDs: seenIDs, environment: context.environment)
    }

    static func dismantleNSView(_: NSScrollView, coordinator: Coordinator) { coordinator.stop() }

    // MARK: - Coordinator

    @MainActor final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
        let actions = SidebarNativeActions()
        weak var scroll: NSScrollView?
        weak var outline: SidebarOwnedOutlineView?
        var boxes: [SidebarNativeItemBox] = []
        var cells = SidebarNativeCellRegistry()
        var boxesByID: [SidebarDisplayID: SidebarNativeItemBox] = [:]
        var indexesByID: [SidebarDisplayID: Int] = [:]
        var logicalDisplays: [String: Set<SidebarDisplayID>] = [:]
        /// Never reset on removal or tombstone pruning; only accepted base-guarded results advance it.
        /// Every newly appearing display occurrence therefore gets a fresh native incarnation.
        var birthCounter = 0
        var destinationIndexes: [MonitorDestination: IndexSet] = [:]
        var lastHostedSelectedIDs: Set<SidebarDisplayID> = []
        var appliedEntries: [SidebarListEntry] = []
        var appliedInput: SidebarListPresentation?
        var appliedRevision = 0
        var pendingInput: SidebarListPresentation?
        var detached: Task<SidebarListReconciler.Result?, Never>?
        weak var relay: SidebarNativeTransitionRelay?
        var overlay: [String: SidebarNativeTransition] = [:]
        var environmentRevision = 0
        var measurementHost: NSHostingView<SidebarNativeRow>?
        var measurementCount = 0
        var createdCellCount = 0
        var rootWriteCount = 0
        var nativeOperationCount = 0
        var reconciliationCount = 0
        var rejectedResultCount = 0
        var offMainCalculationSeconds: TimeInterval = 0
        var mainApplySeconds: TimeInterval = 0
        var naturalMeasurementSeconds: TimeInterval = 0
        /// Optional deterministic test barrier; production never installs one.
        var reconciliationBarrier: (@Sendable () async -> Void)?
        var environment = EnvironmentValues()
        var fingerprint: SidebarNativeEnvironmentFingerprint?
        var selection: MonitorDestination?
        var seenIDs: Set<String> = []
        var input: SidebarListPresentation?
        var generation = 0
        var settledGeneration = -1
        var reconciliation: Task<Void, Never>?
        var observers: [NSObjectProtocol] = []
        var applyingSelection = false
        var applyingStructure = false
        var pendingHeights: Set<SidebarDisplayID> = []
        var pendingMounted: Set<SidebarDisplayID> = []
        var deliveryQueued = false
        var knownWidth: CGFloat = 0
        var widthInvalidationQueued = false
        var historyPublication: SidebarNativeHistoryPublication?
        var nativeOperationDepth = 0
        var invalidatingHostedHeights = false
        var pendingHostedHeights: Set<SidebarDisplayID> = []
        /// Deferred prominence refreshes: a `backgroundStyle` callback can fire while AppKit
        /// owns a native operation (inside layout), where a synchronous hosting-root write
        /// crosses that operation boundary. Pending work is coalesced per display ID and bound to the
        /// association token captured when queued; delivery runs only from a queued
        /// main-actor callback outside every native operation, never inside layout.
        var pendingProminenceRefreshes: [SidebarDisplayID: SidebarNativePendingProminence] = [:]
        var prominenceRefreshQueued = false
        var prominenceDeliveryGeneration = 0

        func bind(_ relay: SidebarNativeTransitionRelay?) {
            guard self.relay !== relay else { return }
            if self.relay?.coordinator === self { self.relay?.coordinator = nil }
            self.relay = relay
            relay?.coordinator = self
        }

        func install(scroll: NSScrollView, outline: SidebarOwnedOutlineView) {
            self.scroll = scroll
            self.outline = outline
            outline.dataSource = self
            outline.delegate = self
            outline.onMove = { [weak self] direction in self?.actions.move(direction) }
            outline.onLayout = { [weak self] in self?.didLayout() }
            outline.onWillLayout = { [weak self] in self?.beginNativeOperation() }
            outline.onDidLayout = { [weak self] in self?.endNativeOperation(flushHostedHeights: true) }
            scroll.contentView.postsBoundsChangedNotifications = true
            scroll.contentView.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.queueGeometry() }
                })
            }
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] event in
                    guard let window = event.object as? NSWindow else { return }
                    MainActor.assumeIsolated {
                        guard let self, window === self.outline?.window else { return }
                        self.refreshProminence()
                    }
                })
            }
        }

        func update(presentation: SidebarListPresentation, selection: MonitorDestination?, seenIDs: Set<String>, environment: EnvironmentValues) {
            self.environment = environment
            self.seenIDs = seenIDs
            let nextFingerprint = SidebarNativeEnvironmentFingerprint(environment)
            let environmentChanged = fingerprint != nextFingerprint
            fingerprint = nextFingerprint
            self.selection = selection
            synchronizeSelection()
            if environmentChanged {
                environmentRevision += 1
                invalidateEnvironmentHeights()
            }
            input = presentation
            pendingInput = presentation
            startReconciliation()
        }

        func stop() {
            reconciliation?.cancel()
            detached?.cancel()
            detached = nil
            reconciliation = nil
            generation += 1
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            outline?.onLayout = nil
            outline?.onWillLayout = nil
            outline?.onDidLayout = nil
            outline?.onMove = nil
            outline?.dataSource = nil
            outline?.delegate = nil
            cells.removeAll()
            boxesByID.removeAll()
            pendingProminenceRefreshes.removeAll()
            prominenceRefreshQueued = false
            prominenceDeliveryGeneration += 1
            indexesByID.removeAll()
            logicalDisplays.removeAll()
            destinationIndexes.removeAll()
            lastHostedSelectedIDs.removeAll()
            measurementHost = nil
            actions.reset()
            if relay?.coordinator === self { relay?.coordinator = nil }
            relay = nil
            boxes.removeAll()
            scroll = nil
            outline = nil
        }

    }
}

#if DEBUG
#Preview("Owned sidebar - light") {
    SidebarView(SidebarViewModelMock()).preferredColorScheme(.light)
}

#Preview("Owned sidebar - dark") {
    SidebarView(SidebarViewModelMock()).preferredColorScheme(.dark)
}
#endif
