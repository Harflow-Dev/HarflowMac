//
//  TaskTopBarCaptureHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Testing

// MARK: - TaskTopBarCaptureHostedTests

/// Optional review captures (`HARFLOW_M05_TOPBAR_CAPTURE_DIR`) of the production shell with the real standalone task view,
/// light and dark, following the design pin's `screens-m05-proposal.js` states: `topbar-facts` (all three chips, the pane
/// open on the notices group), `topbar-resource` (a RUNNING task holding `heavy-build`, whose inline resource card sits
/// above the transcript; the resource-return toolbar button is not part of this state) and `topbar-minimum` (1000 by 620
/// points, sidebar open, 120 character title, widest badge, every chip and the resource return). The window appearance is
/// set explicitly to Aqua or Dark Aqua, so a light capture never inherits a dark desktop. The window is captured by the
/// window server, so the principal item and the task toolbar are both in the image. They are evidence for separate
/// visual review; the assertions only require that both are drawn, in the bar, before the image is taken.
@MainActor @Suite(.serialized) struct TaskTopBarCaptureHostedTests {

    enum Scenario: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case facts = "topbar-facts"
        case resource = "topbar-resource"
        case minimum = "topbar-minimum"

        var testDescription: String { rawValue }

        @MainActor var config: TopBarIntegratedFixture.Config {
            switch self {
            case .facts:
                .init(width: 1280, title: "Fix the flaky retry path in the slot release", openPane: true, expandedGroups: [.notices])
            case .resource:
                .init(width: 1280, title: "Run the heavy build and the full test suite", notices: 0, continuity: false, resourceHeld: true)
            case .minimum:
                .init(width: 1000, height: 620, title: TopBarIntegratedFixture.TitleKind.long.text,
                      badge: TopBarIdealWidths.widestBadge(), resourceReturn: true)
            }
        }
    }

    @Test(arguments: Scenario.allCases, [false, true])
    func givenAScenario_whenTheCaptureDirectoryIsSet_thenThePrincipalAndTheTaskToolbarAreCaptured(scenario: Scenario, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_TOPBAR_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // given
        var config = scenario.config
        config.dark = dark
        let fixture = await TopBarIntegratedFixture(config)
        defer { fixture.close() }
        // The activation is re-asserted while waiting: a one-off request can be lost to another application.
        await waitUntil(timeout: 15) {
            fixture.keepActive()
            fixture.pump()
            return NSApp.isActive && fixture.window.isKeyWindow
        }
        var passes = 0
        await waitUntil(timeout: 8) {
            fixture.pump()
            fixture.publish()
            passes += 1
            return passes >= 60
        }
        await DisplayFrames.waitForPresentedFrame()

        // then both halves of the one toolbar are drawn in the bar
        let principal = try #require(fixture.principalItem, "no principal in \(scenario.rawValue); items \(fixture.itemIdentifiers)")
        #expect(fixture.isOnScreen(principal), "principal not on screen in \(scenario.rawValue)")
        #expect(fixture.isOnScreen(fixture.item(TopBarIntegratedFixture.more)), "More not on screen in \(scenario.rawValue)")
        #expect(fixture.isOnScreen(fixture.item(TopBarIntegratedFixture.inspector)), "the inspector toggle not on screen in \(scenario.rawValue)")
        if scenario == .facts { #expect(fixture.hasPane, "no pane in \(scenario.rawValue)") }
        if scenario == .resource {
            await waitUntil(timeout: 8) { fixture.pump(); return fixture.resourceCardTitle("Holding heavy-build") != nil }
            #expect(fixture.resourceCardTitle("Holding heavy-build") != nil, "no inline resource card in \(scenario.rawValue)")
            #expect(fixture.itemRendering("Back to resource slots") == nil, "the resource return is drawn in \(scenario.rawValue)")
        }
        let expectedAppearance: NSAppearance.Name = dark ? .darkAqua : .aqua
        #expect(fixture.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expectedAppearance,
                "the window is not \(expectedAppearance.rawValue) in \(scenario.rawValue)")
        let name = "m05-d1-\(scenario.rawValue)-\(dark ? "dark" : "light")-\(Int(config.width))x\(Int(config.height))"
        try await M04NativeWindowEvidence.record(window: fixture.window, name: name, directory: directory)
    }
}
