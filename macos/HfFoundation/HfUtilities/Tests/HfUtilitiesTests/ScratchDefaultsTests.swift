import Foundation
import HfTestUtilities
import Testing

@MainActor
@Suite struct ScratchDefaultsTests {

    @Test func givenScratchSuite_whenWrittenAndRemoved_thenItStaysOutOfPreferencesAndCleansUp() async throws {
        // given
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let identifier = scratch.directory.lastPathComponent.replacingOccurrences(of: "harflow-defaults-", with: "")
        #expect(UUID(uuidString: identifier) != nil)
        let plist = URL(fileURLWithPath: scratch.suiteName + ".plist")
        #expect(scratch.suiteName.hasPrefix("/"))

        // when
        scratch.defaults.set("value", forKey: "key")
        scratch.defaults.synchronize()
        await waitUntil(timeout: 5) { FileManager.default.fileExists(atPath: plist.path) }

        // then — the value is stored next to the suite path and read back by a second instance.
        #expect(FileManager.default.fileExists(atPath: plist.path), "The scratch plist was not written within 5 seconds")
        #expect(scratch.reopen().string(forKey: "key") == "value")
        let preferences = try realPreferencesEntries()
        #expect(!(preferences ?? []).contains { $0.contains(identifier) }, "A scratch suite leaked into ~/Library/Preferences")

        // when
        scratch.remove()
        await waitUntil(timeout: 5) { !FileManager.default.fileExists(atPath: scratch.directory.path) }

        // then
        #expect(!FileManager.default.fileExists(atPath: scratch.directory.path))
    }

    /// File names in the real user's Preferences folder (read-only), or nil when the folder does not exist. `HOME` may be a scratch directory under the runner.
    private func realPreferencesEntries() throws -> [String]? {
        let entry = try #require(getpwuid(getuid()), "Could not resolve the real home directory")
        let home = String(cString: entry.pointee.pw_dir)
        let folder = URL(fileURLWithPath: home).appendingPathComponent("Library/Preferences")
        do {
            return try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        }
    }
}
