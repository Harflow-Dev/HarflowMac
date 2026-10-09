import AppKit
import SwiftUI

/// Measure realized rows after native layout settles, without adding a SwiftUI geometry dependency
/// to the lazy stack. Coordinates are relative to the scroll document, matching its clip offset.
struct ActivityRowGeometry: NSViewRepresentable {
    let generation: Int
    let measurements: ActivityRowMeasurements
    let onFrame: (CGRect) -> Void

    func makeNSView(context: Context) -> MeasurementView { MeasurementView() }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MeasurementView, context: Context) -> CGSize? {
        CGSize(width: proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 0,
               height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? 0)
    }

    func updateNSView(_ view: MeasurementView, context: Context) {
        measurements.views.add(view)
        if view.generation != generation { view.invalidateMeasurement(); view.generation = generation }
        view.onFrame = onFrame
        view.scheduleMeasurement()
    }

    final class MeasurementView: NSView {
        var onFrame: ((CGRect) -> Void)?
        var generation = -1
        private var scheduled = false
        private var lastFrame: CGRect?

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            scheduleMeasurement()
        }

        override func setFrameOrigin(_ newOrigin: NSPoint) {
            super.setFrameOrigin(newOrigin)
            scheduleMeasurement()
        }

        override func layout() {
            super.layout()
            scheduleMeasurement()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleMeasurement()
        }

        func invalidateMeasurement() {
            lastFrame = nil
            scheduleMeasurement()
        }

        func scheduleMeasurement() {
            guard !scheduled else { return }
            scheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                scheduled = false
                guard window != nil, let document = enclosingScrollView?.documentView else { return }
                var measured = convert(bounds, to: document)
                if !document.isFlipped { measured.origin.y = document.bounds.maxY - measured.maxY }
                guard measured != lastFrame else { return }
                lastFrame = measured
                onFrame?(measured)
            }
        }
    }
}

@MainActor
final class ActivityRowMeasurements {
    let views = NSHashTable<ActivityRowGeometry.MeasurementView>.weakObjects()
    func invalidateMeasurements() {
        for view in views.allObjects { view.invalidateMeasurement() }
    }

    func scheduleMeasurements() {
        for view in views.allObjects { view.scheduleMeasurement() }
    }
}
