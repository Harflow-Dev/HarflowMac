import AppKit
import MonitorCore
@testable import PbUI
import SwiftUI
import Testing

// MARK: - GroupRowSidebarRenderingTests

@MainActor @Suite(.serialized) struct GroupRowSidebarRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark], [false, true])
    func givenHalfFinishedSidebarGroup_whenRendered_thenItsThreePointProgressRetainsDistinctFillAndTrack(scheme: ColorScheme, emphasized: Bool) throws {
        // given — real membership: one finished member and one running member, no invented progress.
        let row = GroupRow(group: group(), sidebarAppearance: SidebarRowAppearance())
            .environment(\.backgroundProminence, emphasized ? .increased : .standard)
        let background: Color = emphasized ? .accentFill : .sidebarBG
        let fixture = row.frame(width: PbRadius.Metrics.groupPreviewWidth)
            .background(background)
            .environment(\.pbReduceMotionOverride, true)

        // when — render the production row twice, then sample the center of its actual 3 pt bar.
        let bitmap = try render(fixture, scheme: scheme)
        let repeated = try render(fixture, scheme: scheme)
        let fill = try swatch(emphasized ? .onAccent : .runningFG, on: background, scheme: scheme)
        let track = try swatch(emphasized ? .sidebarSelectedProgressTrack : .pillFill, on: background, scheme: scheme)
        let y = bitmap.pixelsHigh - Int(2 * PbRadius.Metrics.sidebarRowPaddingVertical + PbRadius.Metrics.sidebarProgressHeight)
        let pixels = (0 ..< bitmap.pixelsWide).compactMap { bitmap.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB) }
        let fillPixels = pixels.filter { matches($0, fill) }.count
        let trackPixels = pixels.filter { matches($0, track) }.count

        // then — both half-width paints must exist at the bar, not merely in title/spinner ink.
        #expect(bitmap.representation(using: .png, properties: [:]) == repeated.representation(using: .png, properties: [:]))
        #expect(fillPixels > Int(PbRadius.Metrics.spacing20))
        #expect(trackPixels > Int(PbRadius.Metrics.spacing20))
        if emphasized || scheme == .light {
            // In ordinary dark mode pillFill equals sidebarBG, so background pixels cannot
            // identify the track's outer edge; the emphasized track is distinct in both modes.
            #expect(abs(fillPixels - trackPixels) <= Int(PbRadius.Metrics.spacing8))
        }
        #expect(!matches(fill, track))
        if emphasized {
            let oldTrack = try swatch(.pillFill, on: background, scheme: scheme)
            let oldTrackPixels = pixels.filter { matches($0, oldTrack) }.count
            #expect(oldTrackPixels == 0, "The old fixed pillFill track must fail the selected bar regression")
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenSharedDefaultGroup_whenRenderedRepeatedly_thenItsUnchangedSystemProgressRemainsDeterministic(scheme: ColorScheme) throws {
        // given — no sidebar appearance: the existing MenuBar path stays a system ProgressView.
        let fixture = GroupRow(group: group())
            .frame(width: PbRadius.Metrics.groupPreviewWidth)
            .background(Color.sidebarBG)
            .environment(\.pbReduceMotionOverride, true)

        // when
        let first = try render(fixture, scheme: scheme)
        let repeated = try render(fixture, scheme: scheme)

        // then
        #expect(first.representation(using: .png, properties: [:]) == repeated.representation(using: .png, properties: [:]))
    }

    private func group() -> ParallelGroup {
        let tasks = [
            TaskInfo(.object(["task_id": .string("running"), "backend": .string("claude"), "status": .string("running"), "group": .string("review")]))!,
            TaskInfo(.object(["task_id": .string("finished"), "backend": .string("codex"), "status": .string("completed"), "group": .string("review")]))!
        ]
        return Lineage.sections(tasks).parallel.first!
    }

    private func render(_ view: some View, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
            renderer.scale = 2
            image = renderer.cgImage
        }
        return NSBitmapImageRep(cgImage: try #require(image))
    }

    private func swatch(_ color: Color, on background: Color, scheme: ColorScheme) throws -> NSColor {
        let bitmap = try render(Rectangle()
.fill(color)
            .frame(width: PbRadius.Metrics.spacing4, height: PbRadius.Metrics.spacing4)
            .background(background), scheme: scheme)
        return try #require(bitmap.colorAt(x: 1, y: 1)?.usingColorSpace(.deviceRGB))
    }

    private func matches(_ pixel: NSColor, _ target: NSColor) -> Bool {
        let tolerance = 0.03
        return pixel.alphaComponent > 0.95
            && abs(pixel.redComponent - target.redComponent) < tolerance
            && abs(pixel.greenComponent - target.greenComponent) < tolerance
            && abs(pixel.blueComponent - target.blueComponent) < tolerance
    }
}
