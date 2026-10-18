import Foundation
@testable import MonitorCore
import Testing

@Suite
struct ToolLocatorTests {
    @Test
    func givenAnOverrideAndUvBin_whenBuildingSearchDirectories_thenTheyAreOrderedAndDeduped() {
        // given / when
        let locator = ToolLocator(overrideDirectory: " ~/custom ", home: "/Users/u", uvToolBin: "/Users/u/.local/bin\n", isExecutable: { _ in false })
        let custom = ("~/custom" as NSString).expandingTildeInPath
        // then
        #expect(locator.searchDirectories == [custom, "/Users/u/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    @Test
    func givenSeveralDirectoriesHoldingABinary_whenLocated_thenTheFirstOneWins() throws {
        // given
        let present: Set = ["/opt/homebrew/bin/polybridge-ctl", "/usr/local/bin/polybridge-ctl", "/uv/polybridge-setup"]
        let locator = ToolLocator(overrideDirectory: nil, home: "/h", uvToolBin: "/uv", isExecutable: { present.contains($0) })
        // when / then
        try #expect(try locator.locate("polybridge-ctl").get() == "/opt/homebrew/bin/polybridge-ctl")
        try #expect(try locator.locate("polybridge-setup").get() == "/uv/polybridge-setup")
    }

    @Test
    func givenAnOverrideDirectory_whenLocating_thenItWinsAndAMissAisListsWhereItLooked() throws {
        // given
        let locator = ToolLocator(
            overrideDirectory: "/mine", home: "/h", uvToolBin: nil,
            isExecutable: { $0 == "/mine/polybridge-ctl" || $0 == "/usr/local/bin/polybridge-ctl" }
        )
        // when / then
        try #expect(try locator.locate("polybridge-ctl").get() == "/mine/polybridge-ctl")
        guard case .failure(.notFound(_, let searched)) = locator.locate("nope") else { Issue.record("expected .notFound"); return }
        #expect(searched == ["/mine", "/h/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }
}

@Suite
struct LaunchEnvironmentTests {
    @Test
    func givenABaseEnvironment_whenBuildingTheLaunchEnvironment_thenPBVarsAreStrippedAndOpenMonitorAndPathAreSet() {
        // given / when
        let env = LaunchEnvironment.build(
            base: ["HOME": "/h", "PATH": "/usr/bin", "PB_TASK_ID": "t", "PB_ROOT_TASK_ID": "r", "PB_OPEN_MONITOR": "1", "PBX": "kept"],
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin",
            toolDirectory: "/h/.local/bin"
        )
        // then
        #expect(env["PB_TASK_ID"] == nil)
        #expect(env["PB_ROOT_TASK_ID"] == nil)
        #expect(env["PB_OPEN_MONITOR"] == "0")
        #expect(env["PBX"] == "kept")
        #expect(env["HOME"] == "/h")
        #expect(env["PATH"] == "/h/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")
    }

    @Test
    func givenNoLoginPath_whenBuildingTheLaunchEnvironment_thenItFallsBackToTheAppPathOrTheDefault() {
        // given / when / then
        #expect(LaunchEnvironment.build(base: ["PATH": "/a:/b"], loginPath: "", toolDirectory: nil)["PATH"] == "/a:/b")
        #expect(LaunchEnvironment.build(base: [:], loginPath: nil, toolDirectory: "/t")["PATH"] == "/t:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    @Test
    func givenNoArguments_whenReadingTheLoginPathArgv_thenItIsFixedText() {
        // given / when / then
        #expect(LaunchEnvironment.loginPathArgv == ["/bin/zsh", "-l", "-c", "printf %s \"$PATH\""])
    }
}
