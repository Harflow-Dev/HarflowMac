import AppKit
@testable import MainWindowFeature
import PbUI
import SwiftUI
import Testing

// MARK: - SidebarBackendFilterLabelTests

@MainActor @Suite(.serialized) struct SidebarBackendFilterLabelTests {
    @Test(arguments: [5, 40], [ColorScheme.light, .dark])
    func givenCatalogDots_whenRenderedWithChevron_thenTheirPaintedBoundsDoNotOverlap(count: Int, scheme: ColorScheme) throws {
        // given — the actual menu label, independently rendered so native menu chrome cannot
        // obscure its internal geometry. The large catalog exercises the wrapped grid path.
        let known = ["claude", "codex", "vibe", "opencode", "antigravity"]
        let backends = (0 ..< count - known.count).map { "backend-\($0)" } + known
        let label = SidebarBackendFilterLabel(backendIDs: backends, selectedTitle: nil)
            .frame(width: PbRadius.Metrics.sidebarPreviewWidth - 2 * PbRadius.Metrics.spacing16)
            .fixedSize(horizontal: false, vertical: true)
            .environment(\.colorScheme, scheme)
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var captured: CGImage?
        var lastDotColor: NSColor?
        var chevronColor: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            captured = ImageRenderer(content: label).cgImage
            lastDotColor = renderedColor(BackendStyle.dotColor("antigravity"), scheme: scheme)
            chevronColor = renderedColor(.secondaryText, scheme: scheme)
        }
        let bitmap = NSBitmapImageRep(cgImage: try #require(captured))
        let chevron = try #require(chevronColor)
        let lastDot = try #require(lastDotColor)

        // when — locate the actual opaque paint, including the last dot, rather than merely
        // checking the outer menu frame. Both glyph and dot pixels must exist for this to pass.
        var rightmostDot: Int?
        var leftmostChevron: Int?
        for y in 0 ..< bitmap.pixelsHigh {
            for x in 0 ..< bitmap.pixelsWide {
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                // The final magenta dot is distinguishable from gray glyph antialiasing.
                if matches(pixel, lastDot) { rightmostDot = max(rightmostDot ?? x, x) }
                if matches(pixel, chevron) { leftmostChevron = min(leftmostChevron ?? x, x) }
            }
        }

        // then
        let dotEdge = try #require(rightmostDot, "Catalog dots must be painted")
        let chevronEdge = try #require(leftmostChevron, "The chevron must be painted")
        #expect(dotEdge < chevronEdge, "Actual dot paint at x=\(dotEdge) overlaps chevron paint at x=\(chevronEdge)")
    }

    /// Resolve palette paint through the same renderer/profile as the label, rather than
    /// comparing a dynamic NSColor's device components with color-managed bitmap components.
    private func renderedColor(_ color: Color, scheme: ColorScheme) -> NSColor? {
        let swatch = Rectangle()
.fill(color)
            .frame(width: PbRadius.Metrics.spacing4, height: PbRadius.Metrics.spacing4)
            .environment(\.colorScheme, scheme)
        guard let image = ImageRenderer(content: swatch).cgImage else { return nil }
        return NSBitmapImageRep(cgImage: image).colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB)
    }

    private func matches(_ pixel: NSColor, _ target: NSColor) -> Bool {
        let tolerance = 0.03
        return pixel.alphaComponent > 0.95
            && abs(pixel.redComponent - target.redComponent) < tolerance
            && abs(pixel.greenComponent - target.greenComponent) < tolerance
            && abs(pixel.blueComponent - target.blueComponent) < tolerance
    }
}
