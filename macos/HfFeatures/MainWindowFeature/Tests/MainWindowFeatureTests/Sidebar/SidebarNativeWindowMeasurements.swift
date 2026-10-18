import AppKit
import HfUI

struct HeightSample {
    let rect: CGFloat
    let frame: CGFloat
    let reported: CGFloat

    var native: CGFloat { rect }
    var isWithinHairline: Bool {
        abs(rect - frame) <= HfRadius.Metrics.hairlineStroke
            && abs(rect - reported) <= HfRadius.Metrics.hairlineStroke
            && abs(frame - reported) <= HfRadius.Metrics.hairlineStroke
    }
}

struct SidebarShellGeometry {
    let contentLayout: NSRect
    let searchFrame: NSRect
    let scrollFrame: NSRect
    let effectiveViewportBottom: CGFloat
    let effectiveViewportTop: CGFloat
}
