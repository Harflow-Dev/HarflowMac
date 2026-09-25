import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct TakeoverWrapperTests {
    @Test
    func givenAResumeArgv_whenBuildingWrapperArguments_thenItIsAnArrayAfterTheFixedScript() throws {
        // given
        let argv = ["/Users/u/.local/bin/claude", "--resume", "3c2e91a0"]
        // when / then
        try #expect(
            try TakeoverWrapper.arguments(for: argv)
                == ["-l", "-c", "exec \"$@\"", "polybridge-takeover", "/Users/u/.local/bin/claude", "--resume", "3c2e91a0"]
        )
    }

    @Test
    func givenHostileArgv_whenBuildingTheWrapperCommand_thenItStaysData() throws {
        // given
        let hostile = ["/bin/echo", "$(touch /tmp/pwned)", "; rm -rf ~", "a b", "'\"", "--x=`id`"]
        // when
        let command = try TakeoverWrapper.command(argv: hostile, cwd: "/repo with space", environment: ["PATH": "/usr/bin"])
        // then
        #expect(command.executable == "/bin/zsh")
        #expect(Array(command.arguments.prefix(4)) == ["-l", "-c", "exec \"$@\"", "polybridge-takeover"])
        #expect(Array(command.arguments.dropFirst(4)) == hostile, "each element passes through untouched")
        #expect(command.currentDirectory == "/repo with space")
    }

    @Test
    func givenAHostileArgv_whenTheWrapperReallyExecs_thenItArrivesVerbatim() throws {
        // given
        // Run the fixed script (without -l, so no login files are read) and check that argv
        // arrives intact and nothing in it was evaluated.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let marker = dir.appendingPathComponent("pwned").path
        let args = try TakeoverWrapper.arguments(for: ["/bin/echo", "$(touch \(marker))", "a  b", "*"])
        // when
        let output = try ProcessRunner.runBlocking(
            executable: "/bin/zsh", arguments: ["-f"] + args.dropFirst(), environment: ["PATH": "/usr/bin:/bin"],
            currentDirectory: dir.path, timeout: 10
        )
.get()
        // then
        #expect(String(bytes: output.stdout, encoding: .utf8)! == "$(touch \(marker)) a  b *\n")
        #expect(!FileManager.default.fileExists(atPath: marker))
    }

    @Test
    func givenEmptyArgvOrARelativeCwd_whenBuildingWrapperArguments_thenBothAreRefused() {
        // given / when / then
        #expect(throws: (any Error).self) { try TakeoverWrapper.arguments(for: []) }
        #expect(throws: (any Error).self) { try TakeoverWrapper.arguments(for: [""]) }
        #expect(throws: (any Error).self) { try TakeoverWrapper.command(argv: ["/bin/x"], cwd: "relative", environment: [:]) }
    }

    @Test
    func givenABaseEnvironment_whenBuildingTheTerminalEnvironment_thenTaskIdIsDroppedAndMonitorFlagIsForced() {
        // given / when
        let env = TakeoverWrapper.terminalEnvironment(["PB_TASK_ID": "t", "PATH": "/p", "PB_OPEN_MONITOR": "1"])
        // then
        #expect(env["PB_TASK_ID"] == nil)
        #expect(env["PB_OPEN_MONITOR"] == "0")
        #expect(env["TERM"] == "xterm-256color")
        #expect(env["PATH"] == "/p")
    }

    @Test
    func givenAnInteractiveBackend_whenBuildingItsCommand_thenItRunsTheBareCLIThroughTheWrapper() throws {
        // given / when
        let command = try InteractiveSession.command(backend: "codex", repo: "/r", environment: [:])
        // then
        #expect(command.arguments == ["-l", "-c", "exec \"$@\"", "polybridge-takeover", "codex"])
        #expect(throws: (any Error).self) { try InteractiveSession.command(backend: "../evil", repo: "/r", environment: [:]) }
        #expect(throws: (any Error).self) { try InteractiveSession.command(backend: "-x", repo: "/r", environment: [:]) }
    }
}

@Suite(.serialized)
struct TerminalAppHandoffTests {
    let grant = TakeoverGrant(argv: ["/bin/echo", "$(id)", "two words"], cwd: "/tmp", sessionID: "s", note: "")

    @Test
    func givenAGrant_whenBuildingHandoffFiles_thenTheScriptIsFixedTextAndDataIsNulSeparated() throws {
        // given / when
        let files = try TerminalAppHandoff.files(ctl: "/u/.local/bin/polybridge-ctl", taskID: "t1", grant: grant)
        // then
        #expect(files.script == TerminalAppHandoff.script)
        #expect(!files.script.contains("t1"))
        #expect(!files.script.contains("$(id)"))
        #expect(files.meta == Data("/u/.local/bin/polybridge-ctl\u{0}t1\u{0}/tmp\u{0}".utf8))
        #expect(files.argv == Data("/bin/echo\u{0}$(id)\u{0}two words\u{0}".utf8))
        #expect(throws: (any Error).self) { try TerminalAppHandoff.files(ctl: "relative", taskID: "t1", grant: grant) }
        #expect(throws: (any Error).self) {
            try TerminalAppHandoff.files(ctl: "/c", taskID: "t1", grant: TakeoverGrant(argv: ["/a\u{0}b"], cwd: "/tmp", sessionID: nil, note: ""))
        }
    }

    @Test
    func givenAWrittenHandoffScript_whenRun_thenItAttachesItsOwnPidThenExecsVerbatim() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("ctl.log").path
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: #"printf '%s|' "$@" > '\#(log)'; echo "$PPID" >> '\#(log)'"#)
        let files = try TerminalAppHandoff.files(ctl: ctl, taskID: "t1", grant: grant)
        let script = try TerminalAppHandoff.write(files, under: dir)
        // when
        // `zsh -f`: the same script, without reading the user's login files.
        let output = try ProcessRunner.runBlocking(
            executable: "/bin/zsh", arguments: ["-f", script.path],
            environment: ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "leak"], currentDirectory: nil, timeout: 10
        )
.get()
        // then
        #expect(output.exitCode == 0, "\(output.stderr)")
        #expect(String(bytes: output.stdout, encoding: .utf8)! == "$(id) two words\n")
        let logged = try String(contentsOfFile: log, encoding: .utf8)
        #expect(logged.hasPrefix("takeover-attach|--pid="), "\(logged)")
        #expect(logged.contains("|--json|--|t1|"), "\(logged)")
        // The pid it attached is the script's own, which then became the CLI by `exec`.
        let attached = logged.components(separatedBy: "--pid=").last?.components(separatedBy: "|").first
        let parent = logged.components(separatedBy: "|").last?.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(attached == parent, "\(logged)")
        #expect(!FileManager.default.fileExists(atPath: script.path), "the hand-off files are removed before exec")
    }

    @Test
    func givenPBEnvironmentVariables_whenTheHandoffScriptRuns_thenAllAreDroppedExceptOpenMonitor() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: "exit 0")
        let files = try TerminalAppHandoff.files(ctl: ctl, taskID: "t1", grant: TakeoverGrant(argv: ["/usr/bin/env"], cwd: "/tmp", sessionID: nil, note: ""))
        let script = try TerminalAppHandoff.write(files, under: dir)
        // when
        // Terminal.app's environment is its own; any PB_* in it must not reach the session.
        let env = ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "t", "PB_MAX_DEPTH": "1", "PB_LIVE_IDLE_SECONDS": "9", "PB_OPEN_MONITOR": "1"]
        let output = try ProcessRunner.runBlocking(
            executable: "/bin/zsh", arguments: ["-f", script.path], environment: env, currentDirectory: nil, timeout: 10
        )
.get()
        // then
        let pb = String(bytes: output.stdout, encoding: .utf8)!.split(separator: "\n").filter { $0.hasPrefix("PB_") }
        #expect(pb == ["PB_OPEN_MONITOR=0"])
    }

    @Test
    func givenAnAttachThatFails_whenTheHandoffScriptRuns_thenItRefusesToStartTheSession() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: "exit 1")
        let marker = dir.appendingPathComponent("ran").path
        let files = try TerminalAppHandoff.files(
            ctl: ctl, taskID: "t1", grant: TakeoverGrant(argv: ["/usr/bin/touch", marker], cwd: "/tmp", sessionID: nil, note: "")
        )
        let script = try TerminalAppHandoff.write(files, under: dir)
        // when
        let output = try ProcessRunner.runBlocking(
            executable: "/bin/zsh", arguments: ["-f", script.path], environment: ["PATH": "/usr/bin:/bin"], currentDirectory: nil, timeout: 10
        )
.get()
        // then
        #expect(output.exitCode == 1)
        #expect(!FileManager.default.fileExists(atPath: marker), "no attach, no session")
    }
}

@Suite
struct MonitorURLTests {
    @Test
    func givenVariousMonitorURLs_whenExtractingTheTaskID_thenOnlyWellFormedTaskURLsResolve() {
        // given / when / then
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/3c2e91a0-aaaa")!) == "3c2e91a0-aaaa")
        #expect(MonitorURL.taskID(from: URL(string: "POLYBRIDGE-MONITOR://task/abc")!) == "abc")
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/../etc")!) == nil)
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/a/b")!) == nil)
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://other/abc")!) == nil)
        #expect(MonitorURL.taskID(from: URL(string: "https://task/abc")!) == nil)
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/_leading")!) == nil)
        #expect(MonitorURL.taskID(from: URL(string: "polybridge-monitor://task/" + String(repeating: "a", count: 65))!) == nil)
    }
}
