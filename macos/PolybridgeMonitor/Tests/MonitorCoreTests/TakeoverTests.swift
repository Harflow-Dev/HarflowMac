import XCTest
@testable import MonitorCore

final class TakeoverWrapperTests: XCTestCase {
    func testArgvIsAnArrayAfterTheFixedScript() throws {
        let argv = ["/Users/u/.local/bin/claude", "--resume", "3c2e91a0"]
        XCTAssertEqual(try TakeoverWrapper.arguments(for: argv), ["-l", "-c", "exec \"$@\"", "polybridge-takeover", "/Users/u/.local/bin/claude", "--resume", "3c2e91a0"])
    }

    func testHostileArgvStaysData() throws {
        let hostile = ["/bin/echo", "$(touch /tmp/pwned)", "; rm -rf ~", "a b", "'\"", "--x=`id`"]
        let command = try TakeoverWrapper.command(argv: hostile, cwd: "/repo with space", environment: ["PATH": "/usr/bin"])
        XCTAssertEqual(command.executable, "/bin/zsh")
        XCTAssertEqual(Array(command.arguments.prefix(4)), ["-l", "-c", "exec \"$@\"", "polybridge-takeover"])
        XCTAssertEqual(Array(command.arguments.dropFirst(4)), hostile, "each element passes through untouched")
        XCTAssertEqual(command.currentDirectory, "/repo with space")
    }

    func testTheWrapperReallyExecsTheArgvVerbatim() throws {
        // Run the fixed script (without -l, so no login files are read) and check that argv
        // arrives intact and nothing in it was evaluated.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pwned").path
        let args = try TakeoverWrapper.arguments(for: ["/bin/echo", "$(touch \(marker))", "a  b", "*"])
        let output = try ProcessRunner.runBlocking(executable: "/bin/zsh", arguments: ["-f"] + args.dropFirst(), environment: ["PATH": "/usr/bin:/bin"], currentDirectory: dir.path, timeout: 10).get()
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "$(touch \(marker)) a  b *\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker))
    }

    func testRefusesEmptyArgvAndRelativeCwd() {
        XCTAssertThrowsError(try TakeoverWrapper.arguments(for: []))
        XCTAssertThrowsError(try TakeoverWrapper.arguments(for: [""]))
        XCTAssertThrowsError(try TakeoverWrapper.command(argv: ["/bin/x"], cwd: "relative", environment: [:]))
    }

    func testTerminalEnvironment() {
        let env = TakeoverWrapper.terminalEnvironment(["PB_TASK_ID": "t", "PATH": "/p", "PB_OPEN_MONITOR": "1"])
        XCTAssertNil(env["PB_TASK_ID"])
        XCTAssertEqual(env["PB_OPEN_MONITOR"], "0")
        XCTAssertEqual(env["TERM"], "xterm-256color")
        XCTAssertEqual(env["PATH"], "/p")
    }

    func testInteractiveSessionRunsTheBareCLIThroughTheWrapper() throws {
        let command = try InteractiveSession.command(backend: "codex", repo: "/r", environment: [:])
        XCTAssertEqual(command.arguments, ["-l", "-c", "exec \"$@\"", "polybridge-takeover", "codex"])
        XCTAssertThrowsError(try InteractiveSession.command(backend: "../evil", repo: "/r", environment: [:]))
        XCTAssertThrowsError(try InteractiveSession.command(backend: "-x", repo: "/r", environment: [:]))
    }
}

final class TerminalAppHandoffTests: XCTestCase {
    let grant = TakeoverGrant(argv: ["/bin/echo", "$(id)", "two words"], cwd: "/tmp", sessionID: "s", note: "")

    func testScriptIsFixedTextAndDataIsNulSeparated() throws {
        let files = try TerminalAppHandoff.files(ctl: "/u/.local/bin/polybridge-ctl", taskID: "t1", grant: grant)
        XCTAssertEqual(files.script, TerminalAppHandoff.script)
        XCTAssertFalse(files.script.contains("t1"))
        XCTAssertFalse(files.script.contains("$(id)"))
        XCTAssertEqual(files.meta, Data("/u/.local/bin/polybridge-ctl\u{0}t1\u{0}/tmp\u{0}".utf8))
        XCTAssertEqual(files.argv, Data("/bin/echo\u{0}$(id)\u{0}two words\u{0}".utf8))
        XCTAssertThrowsError(try TerminalAppHandoff.files(ctl: "relative", taskID: "t1", grant: grant))
        XCTAssertThrowsError(try TerminalAppHandoff.files(ctl: "/c", taskID: "t1", grant: TakeoverGrant(argv: ["/a\u{0}b"], cwd: "/tmp", sessionID: nil, note: "")))
    }

    func testScriptAttachesItsOwnPidThenExecsVerbatim() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("ctl.log").path
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: #"printf '%s|' "$@" > '\#(log)'; echo "$PPID" >> '\#(log)'"#)
        let files = try TerminalAppHandoff.files(ctl: ctl, taskID: "t1", grant: grant)
        let script = try TerminalAppHandoff.write(files, under: dir)
        // `zsh -f`: the same script, without reading the user's login files.
        let output = try ProcessRunner.runBlocking(executable: "/bin/zsh", arguments: ["-f", script.path], environment: ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "leak"], currentDirectory: nil, timeout: 10).get()
        XCTAssertEqual(output.exitCode, 0, output.stderr)
        XCTAssertEqual(String(decoding: output.stdout, as: UTF8.self), "$(id) two words\n")
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertTrue(logged.hasPrefix("takeover-attach|--pid="), logged)
        XCTAssertTrue(logged.contains("|--json|--|t1|"), logged)
        // The pid it attached is the script's own, which then became the CLI by `exec`.
        let attached = logged.components(separatedBy: "--pid=").last?.components(separatedBy: "|").first
        let parent = logged.components(separatedBy: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(attached, parent, logged)
        XCTAssertFalse(FileManager.default.fileExists(atPath: script.path), "the hand-off files are removed before exec")
    }

    func testScriptDropsEveryPBVariableBeforeTheSession() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: "exit 0")
        let files = try TerminalAppHandoff.files(ctl: ctl, taskID: "t1", grant: TakeoverGrant(argv: ["/usr/bin/env"], cwd: "/tmp", sessionID: nil, note: ""))
        let script = try TerminalAppHandoff.write(files, under: dir)
        // Terminal.app's environment is its own; any PB_* in it must not reach the session.
        let env = ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "t", "PB_MAX_DEPTH": "1", "PB_LIVE_IDLE_SECONDS": "9", "PB_OPEN_MONITOR": "1"]
        let output = try ProcessRunner.runBlocking(executable: "/bin/zsh", arguments: ["-f", script.path], environment: env, currentDirectory: nil, timeout: 10).get()
        let pb = String(decoding: output.stdout, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("PB_") }
        XCTAssertEqual(pb, ["PB_OPEN_MONITOR=0"])
    }

    func testScriptRefusesToStartWhenAttachFails() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: "exit 1")
        let marker = dir.appendingPathComponent("ran").path
        let files = try TerminalAppHandoff.files(ctl: ctl, taskID: "t1", grant: TakeoverGrant(argv: ["/usr/bin/touch", marker], cwd: "/tmp", sessionID: nil, note: ""))
        let script = try TerminalAppHandoff.write(files, under: dir)
        let output = try ProcessRunner.runBlocking(executable: "/bin/zsh", arguments: ["-f", script.path], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil, timeout: 10).get()
        XCTAssertEqual(output.exitCode, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker), "no attach, no session")
    }
}

final class MonitorURLTests: XCTestCase {
    func testTaskURLs() {
        XCTAssertEqual(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/3c2e91a0-aaaa")!), "3c2e91a0-aaaa")
        XCTAssertEqual(MonitorURL.taskID(from: URL(string: "POLYBRIDGE-MONITOR://task/abc")!), "abc")
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/../etc")!))
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/a/b")!))
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "polybridge-monitor://other/abc")!))
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "https://task/abc")!))
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/_leading")!))
        XCTAssertNil(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/" + String(repeating: "a", count: 65))!))
    }
}
