//
//  InfoPlistContractTests.swift
//  HarflowTests
//
//  Decision 1 ("Make it a regular app") + decision 7 ("App icon"): a source contract test reading
//  the actual `HarflowHost/Info.plist` this repo ships, via `#filePath` rather than a bundled copy —
//  the built app's `Info.plist` is a plain file copy (`build-app.sh`), so the source file is the one
//  true copy to check.
//

import Foundation
@testable import Harflow
import Testing

@Suite struct InfoPlistContractTests {

    @Test func givenTheSourceInfoPlist_whenRead_thenLSUIElementIsAbsentAndTheIconFileIsSet() throws {
        // given — navigate from this test file up to `macos/HarflowHost/Info.plist`:
        // Tests/HarflowTests/InfoPlistContractTests.swift → Tests/HarflowTests →
        // Tests → Harflow → HfFeatures → macos → HarflowHost/Info.plist.
        let infoPlistURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("HarflowHost")
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
