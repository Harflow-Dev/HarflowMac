import XCTest
@testable import MonitorCore

final class ToolLocatorTests: XCTestCase {
    func testSearchOrderAndDedupe() {
        let locator = ToolLocator(overrideDirectory: " ~/custom ", home: "/Users/u", uvToolBin: "/Users/u/.local/bin\n", isExecutable: { _ in false })
        let custom = ("~/custom" as NSString).expandingTildeInPath
        XCTAssertEqual(locator.searchDirectories, [custom, "/Users/u/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }

    func testFirstDirectoryHoldingTheBinaryWins() {
        let present: Set<String> = ["/opt/homebrew/bin/polybridge-ctl", "/usr/local/bin/polybridge-ctl", "/uv/polybridge-setup"]
        let locator = ToolLocator(overrideDirectory: nil, home: "/h", uvToolBin: "/uv", isExecutable: { present.contains($0) })
        XCTAssertEqual(try locator.locate("polybridge-ctl").get(), "/opt/homebrew/bin/polybridge-ctl")
        XCTAssertEqual(try locator.locate("polybridge-setup").get(), "/uv/polybridge-setup")
    }

    func testOverrideWinsAndNotFoundListsWhereItLooked() {
        let locator = ToolLocator(overrideDirectory: "/mine", home: "/h", uvToolBin: nil, isExecutable: { $0 == "/mine/polybridge-ctl" || $0 == "/usr/local/bin/polybridge-ctl" })
        XCTAssertEqual(try locator.locate("polybridge-ctl").get(), "/mine/polybridge-ctl")
        guard case .failure(.notFound(_, let searched)) = locator.locate("nope") else { return XCTFail() }
        XCTAssertEqual(searched, ["/mine", "/h/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"])
    }
}

final class LaunchEnvironmentTests: XCTestCase {
    func testStripsPBAndSetsOpenMonitorAndLoginPath() {
        let env = LaunchEnvironment.build(
            base: ["HOME": "/h", "PATH": "/usr/bin", "PB_TASK_ID": "t", "PB_ROOT_TASK_ID": "r", "PB_OPEN_MONITOR": "1", "PBX": "kept"],
            loginPath: "/opt/homebrew/bin:/usr/bin:/bin",
            toolDirectory: "/h/.local/bin"
        )
        XCTAssertNil(env["PB_TASK_ID"])
        XCTAssertNil(env["PB_ROOT_TASK_ID"])
        XCTAssertEqual(env["PB_OPEN_MONITOR"], "0")
        XCTAssertEqual(env["PBX"], "kept")
        XCTAssertEqual(env["HOME"], "/h")
        XCTAssertEqual(env["PATH"], "/h/.local/bin:/opt/homebrew/bin:/usr/bin:/bin")
    }

    func testFallsBackToTheAppPathWithoutALoginPath() {
        XCTAssertEqual(LaunchEnvironment.build(base: ["PATH": "/a:/b"], loginPath: "", toolDirectory: nil)["PATH"], "/a:/b")
        XCTAssertEqual(LaunchEnvironment.build(base: [:], loginPath: nil, toolDirectory: "/t")["PATH"], "/t:/usr/bin:/bin:/usr/sbin:/sbin")
    }

    func testLoginPathArgvIsFixed() {
        XCTAssertEqual(LaunchEnvironment.loginPathArgv, ["/bin/zsh", "-l", "-c", "printf %s \"$PATH\""])
    }
}
