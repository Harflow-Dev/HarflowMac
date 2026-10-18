//
//  MenuBarIconLoaderTests.swift
//  PolybridgeMonitorTests
//
//  Decision 8 ("Menu bar icon uses the P logo"): `loadMenuBarIcon(from:)` against the real source
//  `Resources/` folder (via `#filePath`, the same navigation `InfoPlistContractTests` uses) and
//  against an empty bundle standing in for "the resource isn't there".
//

import AppKit
import Foundation
@testable import PolybridgeMonitor
import Testing

@Suite struct MenuBarIconLoaderTests {

    @Test func givenTheSourceResourcesBundle_whenLoadingTheMenuBarIcon_thenItReturnsATemplateImageWithBothRepresentations() throws {
        // given — Tests/PolybridgeMonitorTests/MenuBarIconLoaderTests.swift → Tests/PolybridgeMonitorTests →
        // Tests → PolybridgeMonitor → Resources, which holds `menubarTemplate.png`/`@2x.png` directly.
        let resourcesURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
        let bundle = try #require(Bundle(url: resourcesURL))

        // when
        let icon = loadMenuBarIcon(from: bundle)

        // then
        let unwrapped = try #require(icon)
        #expect(unwrapped.isTemplate)
        #expect(unwrapped.representations.count == 2)
    }

    @Test func givenAnEmptyBundle_whenLoadingTheMenuBarIcon_thenItReturnsNil() throws {
        // given
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let bundle = try #require(Bundle(url: tempDir))

        // when
        let icon = loadMenuBarIcon(from: bundle)

        // then
        #expect(icon == nil)
    }
}
