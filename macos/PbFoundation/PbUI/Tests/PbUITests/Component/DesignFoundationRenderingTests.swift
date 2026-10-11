import AppKit
@testable import PbUI
import SwiftUI
import Testing

// MARK: - DesignFoundationRenderingTests

/// Renders the shared design foundation (status, buttons, dots, cards, forms, segmented control)
/// offscreen in light and dark, deterministically under Reduce Motion, and covers the
/// presentation-only motion override's true/false/nil resolution. Ordinary runs never write a
/// file; PNGs land on disk only when `PB_DESIGN_FOUNDATION_OUTPUT` names a staging directory
/// inside the system temporary directory.
@MainActor @Suite(.serialized) struct DesignFoundationRenderingTests {

    // MARK: Motion resolution

    @Test func givenMotionOverride_whenResolvingReduceMotion_thenAnOverrideWinsAndNilFallsBack() {
        // given / when / then — `nil` follows the system setting; `true`/`false` force it either way.
        #expect(PbMotion.reduceMotion(override: nil, system: true))
        #expect(!PbMotion.reduceMotion(override: nil, system: false))
        #expect(PbMotion.reduceMotion(override: true, system: false))
        #expect(!PbMotion.reduceMotion(override: false, system: true))
    }

    // MARK: Deterministic rendering

    @Test func givenGroupedActivityCard_whenRendered_thenItsFullOnePointBorderMatchesTheReference() async throws {
        for dark in [false, true] {
            // given — a blank card isolates the border from row content. Padding leaves room for
            // the outer half of the centered stroke, including its rounded corners, at 2×.
            let card = GroupedActivityCard {
                Color.cardFill.frame(height: PbRadius.Metrics.spacing20 * 4)
            }
            let reference = RoundedRectangle(cornerRadius: PbRadius.card)
                .fill(Color.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: PbRadius.card)
                        .stroke(Color.cardBorder, lineWidth: PbRadius.Metrics.hairlineStroke)
                )
                .frame(height: PbRadius.Metrics.spacing20 * 4)

            // when
            let actual = try await renderPNG(cardBorderFixture(card, dark: dark), dark: dark)
            let expected = try await renderPNG(cardBorderFixture(reference, dark: dark), dark: dark)

            // then — the reference has the complete specified 1 pt stroke, with no clipping.
            #expect(actual.png.elementsEqual(expected.png), "The \(dark ? "dark" : "light") card must retain both halves of its 1 pt border")
        }
    }

    private func cardBorderFixture(_ card: some View, dark: Bool) -> some View {
        card
            .frame(width: PbRadius.Metrics.activityPreviewWidth)
            .padding(PbRadius.Metrics.spacing20)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.pbReduceMotionOverride, true)
            .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)
            .background(Color.windowBG)
    }

    @Test func givenTakenOverAnnotation_whenRendered_thenPixelsDifferFromTheUnannotatedBadge() async throws {
        for dark in [false, true] {
            // given — identical completed badges, with only the taken-over annotation differing.
            // when — render both appearances with dense sampling for the small badge content.
            let ordinary = try await renderPNG(badgeFixture(takenOver: false, dark: dark), dark: dark,
                                               sampleStride: Int(PbRadius.Metrics.spacing2))
            let takenOver = try await renderPNG(badgeFixture(takenOver: true, dark: dark), dark: dark,
                                                sampleStride: Int(PbRadius.Metrics.spacing2))
            // then — both draw content and the annotation changes visible pixels.
            #expect(ordinary.distinctSampledColors > 8)
            #expect(takenOver.distinctSampledColors > 8)
            #expect(ordinary.png != takenOver.png, "Taken-over state must change visible pixels, not just accessibility")
        }
    }

    private func badgeFixture(takenOver: Bool, dark: Bool) -> some View {
        StatusBadge(status: .completed, elapsedText: "6:52", isTakenOver: takenOver)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.pbReduceMotionOverride, true)
            .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)
            .background(Color.windowBG)
    }

    @Test func givenFoundationFixtures_whenRenderedTwiceUnderReduceMotion_thenTheyAreByteIdentical() async throws {
        for dark in [false, true] {
            // given — Reduce Motion forced on so no animated element (spinner, thumb) advances
            // between renders; this is the presentation override doing its deterministic job.
            let fixture = DesignFoundationFixture()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.pbReduceMotionOverride, true)
                .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)

            // when
            let first = try await renderPNG(fixture, dark: dark)
            let second = try await renderPNG(fixture, dark: dark)

            // then — two renders of the same fixture are byte-identical, and the fixture is not a
            // blank surface.
            #expect(first.png == second.png, "the \(dark ? "dark" : "light") foundation render is not deterministic")
            #expect(first.distinctSampledColors > 8, "the \(dark ? "dark" : "light") foundation render looks blank")
        }
    }

    @Test func givenFoundationFixtures_whenRenderedWithMotionLeftToTheSystem_thenTheyProduceContent() async throws {
        for dark in [false, true] {
            // given — no override: the nil fallback path, spinner and thumb left to the system.
            let fixture = DesignFoundationFixture()
                .environment(\.colorScheme, dark ? .dark : .light)
                .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)

            // when
            let png = try await renderPNG(fixture, dark: dark)

            // then — a single frame renders real content (its animated parts are not compared
            // across frames, only asserted to draw).
            #expect(png.distinctSampledColors > 8, "the \(dark ? "dark" : "light") foundation render looks blank")
        }
    }

    // MARK: Opt-in reference output

    @Test func givenOptInStagingDirectory_whenFoundationFixturesRender_thenWriteDesignReferences() async throws {
        // given
        guard let path = ProcessInfo.processInfo.environment["PB_DESIGN_FOUNDATION_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        try #require(
            output.deletingLastPathComponent() == FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                && output.lastPathComponent.hasPrefix("pb-design-foundation."),
            "PB_DESIGN_FOUNDATION_OUTPUT must sit inside the system temporary directory"
        )
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // when
        for dark in [false, true] {
            let fixture = DesignFoundationFixture()
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.pbReduceMotionOverride, true)
                .frame(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)
            let png = try await renderPNG(fixture, dark: dark)
            try png.png.write(to: output.appendingPathComponent("foundation-\(dark ? "dark" : "light").png"))

            // then
            #expect(png.distinctSampledColors > 8, "the \(dark ? "dark" : "light") foundation capture looks blank")
        }
    }

    /// Renders `view` offscreen at 2× and returns its PNG bytes plus a sampled colour variety.
    private func renderPNG(_ view: some View, dark: Bool,
                           sampleStride: Int = PbRadius.Metrics.foundationSampleStride) async throws -> (png: Data, distinctSampledColors: Int) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await DisplayFrames.waitForPresentedFrame()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: PbRadius.Metrics.foundationPixelWidth, pixelsHigh: PbRadius.Metrics.foundationPixelHeight,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: PbRadius.Metrics.foundationWidth, height: PbRadius.Metrics.foundationHeight)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(host.fittingSize.height <= PbRadius.Metrics.foundationHeight, "All foundation sections must fit the fixture")
        #expect(bitmap.pixelsWide == PbRadius.Metrics.foundationPixelWidth && bitmap.pixelsHigh == PbRadius.Metrics.foundationPixelHeight)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        let sampledColors = Set(
            stride(from: 0, to: bitmap.pixelsWide, by: sampleStride).flatMap { x in
                stride(from: 0, to: bitmap.pixelsHigh, by: sampleStride).compactMap { y in bitmap.colorAt(x: x, y: y)?.description }
            }
        )
        return (png, sampledColors.count)
    }
}

// MARK: - DesignFoundationFixture

/// The deterministic shared-component fixture: every Phase 0 foundation in one view, on dummy
/// data only — no backend calls, no invented production values.
struct DesignFoundationFixture: View {
    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
            foundationStatusSection
            foundationButtonSection
            SlidingSegmentedControl(
                options: ["Activity", "Summary", "Prompt"].map { ($0, $0) },
                selection: .constant("Activity")
            )
            foundationCardSection
            foundationFormSection
        }
        .padding(PbRadius.Metrics.spacing20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.windowBG)
    }

    private var foundationStatusSection: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            Text("Status").font(.pb(.headline, weight: .semibold))
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .running, elapsedText: "1:30")
                StatusBadge(status: .completed, elapsedText: "6:52")
                StatusBadge(status: .other("needs_attention"))
                StatusBadge(status: .failed)
            }
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .other("pending"))
                StatusBadge(status: .completed, elapsedText: "6:52", isTakenOver: true)
            }
            HStack(spacing: PbRadius.Metrics.spacing8) {
                StatusBadge(status: .timedOut)
                StatusBadge(status: .cancelled)
                StatusBadge(status: .other("settling"))
                StatusBadge(status: .other("unknown"))
            }
            HStack(spacing: PbRadius.Metrics.spacing12) {
                StatusIcon(status: .running)
                StatusIcon(status: .completed)
                StatusIcon(status: .cancelled)
                StatusIcon(status: .other("needs_attention"))
            }
            HStack(spacing: PbRadius.Metrics.spacing14) {
                BackendLabel(backend: "claude")
                BackendLabel(backend: "vibe")
                BackendLabel(backend: "antigravity")
                BackendDotStack(backends: ["codex", "opencode"])
            }
        }
    }

    private var foundationButtonSection: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing8) {
            HStack(spacing: PbRadius.Metrics.spacing12) {
            Button("Run") {}.buttonStyle(MonitorButtonStyle(.primary))
            Button("Edit with agent") {}.buttonStyle(MonitorButtonStyle(.tinted))
            Button("Cancel run", role: .destructive) {}.buttonStyle(MonitorButtonStyle(.destructive))
            Button("Continue in terminal") {}.buttonStyle(QuietButtonStyle())
            Button("Take over", role: .destructive) {}.buttonStyle(QuietButtonStyle())
            Button {} label: { Image(systemName: "sidebar.right") }.buttonStyle(QuietButtonStyle(isSelected: true))
            Button("Glass") {}.buttonStyle(MonitorButtonStyle(.glass))
            }
            HStack(spacing: PbRadius.Metrics.spacing12) {
                Button("Outlined") {}.buttonStyle(QuietButtonStyle(isFilled: false))
                Button("Disabled run") {}.buttonStyle(MonitorButtonStyle(.primary)).disabled(true)
                Button("Disabled quiet") {}.buttonStyle(QuietButtonStyle()).disabled(true)
            }
        }
    }

    private var foundationCardSection: some View {
        GroupedActivityCard {
            ActivityCardRow {
                HStack(spacing: PbRadius.Metrics.spacing8) {
                    Image(systemName: "doc.text").font(.pb(.body)).foregroundStyle(Color.secondaryText)
                    Text("Edited Example.swift").font(.pb(.body, weight: .medium))
                }
            }
            ActivityCardDivider()
            ActivityDiffBody {
                ActivityDiffLine(kind: .removed, text: "- let value = 1")
                ActivityDiffLine(kind: .added, text: "+ let value = 2")
            }
        }
    }

    private var foundationFormSection: some View {
        GroupedForm {
            GroupedFormRow("Decision attempts") {
                CompactStepper("Decision attempts", value: .constant(3), in: 1 ... 10)
            }
            GroupedFormDivider()
            GroupedFormRow("Model") {
                GroupedFormPopup("Model", options: [("default", "Default"), ("fast", "Fast")], selection: .constant("default"))
            }
        }
    }
}
