import AppKit
import SwiftUI

/// A synchronous cancellation handoff tied to the observer's current scoped native binding.
struct ParallelScrollRestorationCancellation {
    let observer: ParallelScrollObservationView
    let scrollView: NSScrollView
    let generation: Int
    let isUpward: Bool
}

// MARK: - ParallelScrollObserver

/// Native observation also covers scrollbar and keyboard movement on macOS 14.
struct ParallelScrollObserver: NSViewRepresentable {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    var columnIDs: [String] = []
    var columnStride: CGFloat = 0
    var horizontalPosition: ParallelViewportPosition?
    var explicitNavigationID: String?
    var restorationOffset: CGFloat?
    var restorationActive = false
    var restorationGeneration = 0
    var followsLive = false
    var onRestorationCancelled: ((ParallelScrollRestorationCancellation) -> Int?)?
    var onViewportSize: ((CGSize) -> Void)?
    /// Native vertical geometry separates the clip viewport from scrollbar-independent outer width.
    var onNativeViewportGeometry: ((CGSize, CGFloat) -> Void)?
    var onUpwardIntent: (() -> Void)?
    /// Scoped native identity (a List-backed feed's own NSScrollView, disclosed through HfUI's
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
        view.horizontalPosition = horizontalPosition
        view.explicitNavigationID = explicitNavigationID
        view.configure(ids: columnIDs, stride: columnStride, restorationOffset: restorationOffset,
                       restorationActive: restorationActive, generation: restorationGeneration)
        view.bindNativeIdentity(nativeIdentity)
        view.updateWheelMonitor()
    }
}

// MARK: - Horizontal native input

extension ParallelScrollObserver {
    static func isHorizontalNavigation(_ event: NSEvent, in scroll: NSScrollView) -> Bool {
        guard event.window === scroll.window else { return false }
        switch event.type {
        case .keyDown:
            guard let responder = scroll.window?.firstResponder as? NSView,
                  responder === scroll || responder.isDescendant(of: scroll),
                  let key = event.charactersIgnoringModifiers?.unicodeScalars.first?.value,
                  [UInt32(NSLeftArrowFunctionKey), UInt32(NSRightArrowFunctionKey), UInt32(NSHomeFunctionKey),
                   UInt32(NSEndFunctionKey), UInt32(NSPageUpFunctionKey), UInt32(NSPageDownFunctionKey)].contains(key) else { return false }
        case .scrollWheel:
            guard scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)),
                  event.scrollingDeltaX != 0 || (event.modifierFlags.contains(.shift) && event.scrollingDeltaY != 0) else { return false }
        case .leftMouseDown:
            guard let scroller = scroll.horizontalScroller, !scroller.isHidden,
                  scroller.bounds.contains(scroller.convert(event.locationInWindow, from: nil)) else { return false }
        default: return false
        }
        return true
    }
}
