//
//  InfoPlistContractTests.swift
//  PolybridgeMonitorTests
//
//  Decision 1 ("Make it a regular app") + decision 7 ("App icon"): a source contract test reading
//  the actual `Resources/Info.plist` this repo ships, via `#filePath` rather than a bundled copy —
//  the built app's `Info.plist` is a plain file copy (`build-app.sh`), so the source file is the one
//  true copy to check.
//

import Foundation
@testable import PolybridgeMonitor
import Testing

@Suite struct InfoPlistContractTests {

    @Test func givenTheSourceInfoPlist_whenRead_thenLSUIElementIsAbsentAndTheIconFileIsSet() throws {
        // given — navigate from this test file up to `PolybridgeMonitor/Resources/Info.plist`:
        // Tests/PolybridgeMonitorTests/InfoPlistContractTests.swift → Tests/PolybridgeMonitorTests →
        // Tests → PolybridgeMonitor → Resources/Info.plist.
        let infoPlistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources")
            .appendingPathComponent("Info.plist")
        let data = try Data(contentsOf: infoPlistURL)

        // when
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let dict = try #require(plist as? [String: Any])

        // then
        #expect(dict["LSUIElement"] == nil)
        #expect(dict["CFBundleIconFile"] as? String == "AppIcon")
    }
}
