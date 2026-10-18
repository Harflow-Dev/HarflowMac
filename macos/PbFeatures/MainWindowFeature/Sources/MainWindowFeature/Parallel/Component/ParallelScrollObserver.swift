import AppKit
import SwiftUI

// MARK: - ParallelScrollObserver

/// Native observation also covers scrollbar and keyboard movement on macOS 14.
struct ParallelScrollObserver: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var columnIDs: [String] = []
    var columnStride: CGFloat = 0
    var restorationOffset: CGFloat?
    var restorationActive = false
    var restorationGeneration = 0
    var followsLive = false
    var onRestorationCancelled: ((ParallelScrollRestorationCancellation) -> Int?)?
    var onViewportSize: ((CGSize) -> Void)?
    /// Native vertical geometry separates the clip viewport from scrollbar-independent outer width.
    var onNativeViewportGeometry: ((CGSize, CGFloat) -> Void)?
    var onUpwardIntent: (() -> Void)?
    /// Scoped native identity (a List-backed feed's own NSScrollView, disclosed through PbUI's
    /// `.scrollChromeScope(onNativeScrollView:)` bounded marker-pair relay). When present the
    /// observation view attaches only to the identities this holder delivers — never to its own
    /// `enclosingScrollView` — and an explicit nil fails closed. Absent (the default), both the
    /// horizontal lane and every ScrollView-backed surface keep their exact prior behaviour.
    var nativeIdentity: ParallelScrollNativeIdentity?
    /// The reading-anchor provider of a native-identity vertical surface, held weakly by the
    /// observation view. Absent (the default), every observer — the horizontal lane, every
    /// ScrollView-backed surface — keeps its exact prior behaviour.
    var anchorProvider: ParallelScrollAnchorProvider?
    let onPosition: (CGFloat, CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> ParallelScrollObservationView {
        let view = ParallelScrollObservationView()
        updateNSView(view, context: context)
        return view
    }

    static func dismantleNSView(_ view: ParallelScrollObservationView, coordinator: ()) {
        view.bindNativeIdentity(nil)
        view.teardownObservation()
    }

    func updateNSView(_ view: ParallelScrollObservationView, context: Context) {
        view.usesNativeIdentity = nativeIdentity != nil
        view.axis = axis
        view.onPosition = onPosition
        view.onViewportSize = onViewportSize
        view.onNativeViewportGeometry = onNativeViewportGeometry
        view.onUpwardIntent = onUpwardIntent
        view.followsLive = followsLive
        view.onRestorationCancelled = onRestorationCancelled
        if let nativeIdentity {
            view.anchorProvider = nativeIdentity.resolvedAnchorProvider(fallback: anchorProvider)
        } else { view.anchorProvider = anchorProvider }
        view.updateWheelMonitor()
        view.configure(ids: columnIDs, stride: columnStride, restorationOffset: restorationOffset,
                       restorationActive: restorationActive, generation: restorationGeneration)
        view.bindNativeIdentity(nativeIdentity)
    }
}
