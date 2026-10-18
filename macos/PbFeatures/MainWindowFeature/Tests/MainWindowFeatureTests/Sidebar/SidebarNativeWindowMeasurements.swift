import AppKit
import PbUI

struct HeightSample {
    let rect: CGFloat
    let frame: CGFloat
    let reported: CGFloat

    var native: CGFloat { rect }
    var isWithinHairline: Bool {
        abs(rect - frame) <= PbRadius.Metrics.hairlineStroke
            && abs(rect - reported) <= PbRadius.Metrics.hairlineStroke
            && abs(frame - reported) <= PbRadius.Metrics.hairlineStroke
    }
}

struct SidebarShellGeometry {
    let contentLayout: NSRect
    let searchFrame: NSRect
    let scrollFrame: NSRect
    let effectiveViewportBottom: CGFloat
    let effectiveViewportTop: CGFloat
}
