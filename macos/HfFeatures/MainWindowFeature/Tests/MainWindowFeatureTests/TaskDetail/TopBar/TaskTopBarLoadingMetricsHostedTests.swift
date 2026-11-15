//
//  TaskTopBarLoadingMetricsHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - TaskTopBarLoadingMetricsHostedTests

/// The known title in the loading bar against the same title in the loaded bar, in the production shell with the real
/// standalone task view: the same font (same text, same drawn width), the same line height and the same vertical
/// position. The horizontal position is measured and printed, not asserted: the principal is centred and the loaded
/// bar is wider, so the title moves sideways when the loaded bar replaces the loading one (accepted by the owner).
/// Needs the AppKit host.
@MainActor @Suite(.serialized) struct TaskTopBarLoadingMetricsHostedTests {

    typealias Fixture = TopBarIntegratedFixture

    /// A title that fits whole at both sizes, so the drawn width reflects the font and not truncation.
    private static let title = Fixture.TitleKind.short.text

    private struct TitleFrame {
        let minX: CGFloat
        let minY: CGFloat
        let width: CGFloat
        let height: CGFloat
    }

    /// The title's accessibility frame relative to its window's origin, once the principal has drawn it.
    private func titleFrame(_ fixture: Fixture) async -> TitleFrame? {
        await waitUntil(timeout: 10) {
            fixture.pump()
            return frame(fixture) != nil
        }
        fixture.pump(times: 30)
        return frame(fixture)
    }

    private func frame(_ fixture: Fixture) -> TitleFrame? {
        guard let principal = fixture.principalItem, let element = fixture.element(labelled: Self.title, in: principal),
              let rect = fixture.screenFrame(ofElement: element) else { return nil }
        let origin = fixture.window.frame.origin
        return TitleFrame(minX: rect.minX - origin.x, minY: rect.minY - origin.y, width: rect.width, height: rect.height)
    }

    @Test(arguments: [CGSize(width: 1280, height: 800), CGSize(width: 1000, height: 620)])
    func givenTheKnownTitle_whenTheLoadedBarReplacesTheLoadingBar_thenFontHeightAndVerticalPositionAreUnchanged(size: CGSize) async throws {
        // given the loading bar with the known title
        var loadingConfig = Fixture.Config()
        loadingConfig.width = size.width
        loadingConfig.height = size.height
        loadingConfig.title = Self.title
        loadingConfig.loading = true
        loadingConfig.loadingTitle = Self.title
        let loading = await Fixture(loadingConfig)
        defer { loading.close() }
        let loadingFrame = try #require(await titleFrame(loading), "the loading bar never drew the known title at \(size)")

        // and the loaded bar of the same title
        var loadedConfig = Fixture.Config()
        loadedConfig.width = size.width
        loadedConfig.height = size.height
        loadedConfig.title = Self.title
        let loaded = await Fixture(loadedConfig)
        defer { loaded.close() }
        let loadedFrame = try #require(await titleFrame(loaded), "the loaded bar never drew the title at \(size)")

        // then the text is drawn in the same font (same width for the same text), on the same line, at the same height
        #expect(abs(loadingFrame.height - loadedFrame.height) <= 0.5, "title height \(loadingFrame.height) vs \(loadedFrame.height)")
        #expect(abs(loadingFrame.minY - loadedFrame.minY) <= 0.5, "title minY \(loadingFrame.minY) vs \(loadedFrame.minY)")
        #expect(abs(loadingFrame.width - loadedFrame.width) <= 0.5, "title width \(loadingFrame.width) vs \(loadedFrame.width)")

        // and the horizontal shift is recorded for the receipt, with no pass or fail on it
        let shift = loadedFrame.minX - loadingFrame.minX
        print("TOPBAR title shift at \(Int(size.width)) x \(Int(size.height)): loading minX \(loadingFrame.minX), "
            + "loaded minX \(loadedFrame.minX), shift \(shift)")
    }
}
