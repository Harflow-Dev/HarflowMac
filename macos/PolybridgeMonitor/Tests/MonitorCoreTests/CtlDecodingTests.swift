import XCTest
@testable import MonitorCore

final class CtlDecodingTests: XCTestCase {
    func decode(_ text: String, stderr: String = "", exit: Int32 = 0, command: String = "list") -> Result<CtlDocument, ToolError> {
        CtlDocument.decode(stdout: json(text), stderr: stderr, exitCode: exit, command: command)
    }

    func testListDecodesBriefsLeniently() throws {
        let result = decode("""
        {"v": 1, "tasks": [
          {"task_id": "a1", "backend": "claude", "session_id": "s", "repo_path": "/r", "status": "running",
           "freedom": "write_in_repo", "started_at": "2026-09-25T01:02:03.123456+00:00", "duration_seconds": 12.5,
           "parent_task_id": null, "spawned_by": null, "root_task_id": "a1", "depth": 0, "max_depth": 2,
           "group": null, "lineage_detected": null, "live_input": true, "notices": ["n"], "owner": {"pid": 3},
           "owned_by_live_server": true, "recovered": true, "taken_over": true, "taken_over_note": "note"},
          {"task_id": "old"},
          {"no_id": true}
        ]}
        """)
        guard case .success(.tasks(let tasks)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(tasks.map(\.taskID), ["a1", "old"])
        let first = tasks[0]
        XCTAssertEqual(first.backend, "claude")
        XCTAssertEqual(first.status, .running)
        XCTAssertTrue(first.liveInput)
        XCTAssertTrue(first.takenOver)
        XCTAssertEqual(first.maxDepth, 2)
        XCTAssertEqual(first.notices, ["n"])
        XCTAssertNotNil(first.startedAt, "microsecond isoformat must parse")
        XCTAssertTrue(first.isRoot)
        // A record from before lineage/live input existed still decodes, with safe defaults.
        XCTAssertEqual(tasks[1].backend, "unknown")
        XCTAssertFalse(tasks[1].liveInput)
        XCTAssertFalse(tasks[1].takenOver)
    }

    func testStatusSnapshotFields() {
        let result = decode("""
        {"v": 1, "task": {"task_id": "t", "status": "completed", "summary": "**done**", "exit_code": 0,
          "base_commit": "abc123", "start_dirty": false, "events_log": "/h/.polybridge/tasks/t.events.jsonl",
          "enforcement": {"commit_push_blocked": false, "direct_commit_commands_denied": true},
          "spawned_by": "p", "depth": 1}}
        """, command: "status")
        guard case .success(.task(let task)) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.summary, "**done**")
        XCTAssertEqual(task.exitCode, 0)
        XCTAssertEqual(task.baseCommit, "abc123")
        XCTAssertEqual(task.startDirty, false)
        XCTAssertEqual(task.enforcement?["direct_commit_commands_denied"], .bool(true))
        XCTAssertFalse(task.isRoot)
    }

    func testErrorDocumentIsARefusalWithItsCode() {
        let result = decode(#"{"v": 1, "error": {"code": "descendants_not_stopped", "message": "task x survived"}}"#, exit: 1, command: "takeover")
        XCTAssertEqual(result, .success(.error(code: "descendants_not_stopped", message: "task x survived")))
        let failure = result.requiringSuccess()
        guard case .failure(let error) = failure else { return XCTFail() }
        XCTAssertEqual(error.refusalCode, "descendants_not_stopped")
        XCTAssertTrue(error.message.contains("sub-task"), error.message)
        XCTAssertTrue(error.message.contains("task x survived"), "the ctl detail is kept: \(error.message)")
    }

    func testCallerUndecidableHasItsOwnExplanation() {
        let error = ToolError.refused(code: "caller_undecidable", message: "ps denied")
        XCTAssertTrue(error.message.contains("could not confirm"), error.message)
        XCTAssertTrue(error.message.contains("ps denied"))
    }

    func testUnknownCodeFallsBackToTheMessage() {
        XCTAssertEqual(ToolError.refused(code: "brand_new", message: "why").message, "why (brand_new)")
    }

    func testUnknownOutcomeIsNotASuccess() {
        let result = decode(#"{"v": 1, "unknown": {"message": "check polybridge-ctl list"}}"#, exit: 3, command: "run")
        guard case .failure(.unknownOutcome(let message)) = result.requiringSuccess() else { return XCTFail() }
        XCTAssertEqual(message, "check polybridge-ctl list")
    }

    func testOtherVersionIsRefused() {
        guard case .failure(.unsupportedVersion(_, let v)) = decode(#"{"v": 2, "tasks": []}"#) else { return XCTFail() }
        XCTAssertEqual(v, "2")
        guard case .failure(.unsupportedVersion(_, let none)) = decode(#"{"tasks": []}"#) else { return XCTFail() }
        XCTAssertEqual(none, "none")
    }

    func testMissingSubcommandFromAnOldCtl() {
        // The new ctl answers a usage error as JSON...
        let jsonUsage = decode(#"{"v": 1, "error": {"code": "usage", "message": "argument command: invalid choice: 'takeover' (choose from list, status)"}}"#, exit: 2, command: "takeover")
        guard case .failure(.unsupportedCommand(_, let command, _)) = jsonUsage else { return XCTFail("\(jsonUsage)") }
        XCTAssertEqual(command, "takeover")
        // ...an older one only in prose on stderr.
        let prose = decode("", stderr: "polybridge-ctl: error: argument command: invalid choice: 'send'", exit: 2, command: "send")
        guard case .failure(let error) = prose, case .unsupportedCommand = error else { return XCTFail("\(prose)") }
        XCTAssertTrue(error.message.contains("predates"), error.message)
    }

    func testGarbageIsUnreadable() {
        guard case .failure(.unreadable(_, 1, let stderr)) = decode("Traceback...", stderr: "boom", exit: 1) else { return XCTFail() }
        XCTAssertEqual(stderr, "boom")
    }

    func testStatusLabels() {
        XCTAssertEqual(TaskStatus("timed_out"), .timedOut)
        XCTAssertEqual(TaskStatus("weird"), .other("weird"))
        XCTAssertTrue(TaskStatus("cancelled").isTerminal)
        XCTAssertFalse(TaskStatus("weird").isTerminal)
    }

    func testTakeoverGrantRequiresAStringArgvAndCwd() {
        XCTAssertNil(TakeoverGrant(["argv": .array([]), "cwd": .string("/r")]))
        XCTAssertNil(TakeoverGrant(["argv": .array([.string("/x"), .number(1)]), "cwd": .string("/r")]))
        XCTAssertNil(TakeoverGrant(["argv": .array([.string("/x")])]))
        let grant = TakeoverGrant(["argv": .array([.string("/bin/claude"), .string("--resume"), .string("s1")]), "cwd": .string("/r"), "session_id": .string("s1"), "note": .string("n")])
        XCTAssertEqual(grant?.argv, ["/bin/claude", "--resume", "s1"])
    }
}

final class CtlClientTests: XCTestCase {
    func testArgvPutsOptionsBeforeJsonAndPositionalsAfterSeparator() {
        XCTAssertEqual(CtlClient.argv("list"), ["list", "--json"])
        XCTAssertEqual(CtlClient.argv("send", positionals: ["t1", "-rf everything"]), ["send", "--json", "--", "t1", "-rf everything"])
        XCTAssertEqual(CtlClient.argv("takeover-attach", options: ["--pid=42"], positionals: ["t1"]), ["takeover-attach", "--pid=42", "--json", "--", "t1"])
    }

    func testRunRequestUsesEqualsForm() {
        let request = RunRequest(backend: "claude", repo: "/r", prompt: "--max-turns 1", freedom: "read_only", group: "g")
        XCTAssertEqual(request.arguments, ["--backend=claude", "--repo=/r", "--prompt=--max-turns 1", "--freedom=read_only", "--group=g"])
    }

    func testEachCommandSendsTheExpectedArgv() async {
        let runner = RecordingRunner { call in
            switch call.arguments.first {
            case "takeover": return ProcessOutput(exitCode: 0, stdout: json(#"{"v":1,"result":{"argv":["/c","--resume","s"],"cwd":"/r","session_id":"s","note":"n"}}"#), stderr: "")
            case "run", "resume": return ProcessOutput(exitCode: 0, stdout: json(#"{"v":1,"result":{"task_id":"new1"}}"#), stderr: "")
            default: return ProcessOutput(exitCode: 0, stdout: json(#"{"v":1,"result":{"status":"queued"}}"#), stderr: "")
            }
        }
        let client = CtlClient(executable: "/fake/polybridge-ctl", environment: ["PB_OPEN_MONITOR": "0"], runner: runner)
        _ = await client.send("t1", text: "hi")
        _ = await client.cancel("t1")
        let grant = await client.takeover("t1")
        _ = await client.takeoverAttach("t1", pid: 99)
        let started = await client.run(RunRequest(backend: "codex", repo: "/r", prompt: "p"))
        let resumed = await client.resume("t1", text: "more")
        XCTAssertEqual(try grant.get().argv, ["/c", "--resume", "s"])
        XCTAssertEqual(try started.get(), "new1")
        XCTAssertEqual(try resumed.get(), "new1")
        XCTAssertEqual(runner.calls.map(\.arguments), [
            ["send", "--json", "--", "t1", "hi"],
            ["cancel", "--json", "--", "t1"],
            ["takeover", "--json", "--", "t1"],
            ["takeover-attach", "--pid=99", "--json", "--", "t1"],
            ["run", "--backend=codex", "--repo=/r", "--prompt=p", "--json"],
            ["resume", "--json", "--", "t1", "more"],
        ])
        XCTAssertTrue(runner.calls.allSatisfy { $0.environment["PB_OPEN_MONITOR"] == "0" })
    }

    func testAgainstAFakeBinary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Echoes its argv back inside a v1 list document, and proves PB_OPEN_MONITOR arrived.
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: """
        printf '{"v":1,"tasks":[{"task_id":"t-%s","backend":"%s","status":"running"}]}\\n' "$#" "$PB_OPEN_MONITOR"
        """)
        let env = LaunchEnvironment.build(base: ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "leak"], loginPath: nil, toolDirectory: dir.path)
        let tasks = try await CtlClient(executable: ctl, environment: env).list().get()
        XCTAssertEqual(tasks.map(\.taskID), ["t-2"], "argv was `list --json`")
        XCTAssertEqual(tasks.first?.backend, "0", "PB_OPEN_MONITOR=0 reached the child")
    }

    func testFakeBinaryWithUnknownVersionDegrades() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: #"echo '{"v": 7, "tasks": []}'"#)
        let result = await CtlClient(executable: ctl, environment: [:]).list()
        guard case .failure(let error) = result, case .unsupportedVersion = error else { return XCTFail("\(result)") }
        XCTAssertTrue(error.message.contains("version 7"), error.message)
    }

    func testMissingBinaryIsALaunchFailure() async {
        let result = await CtlClient(executable: "/nonexistent/polybridge-ctl", environment: [:]).list()
        guard case .failure(.launchFailed) = result else { return XCTFail("\(result)") }
    }

    func testTimeoutEscalatesPastAChildIgnoringSIGTERM() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubborn = try writeFakeTool(dir, name: "stubborn", body: "trap '' TERM; while :; do sleep 1; done")
        let started = Date()
        let output = try ProcessRunner.runBlocking(executable: stubborn, arguments: [], environment: [:], currentDirectory: nil, timeout: 0.5).get()
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testNoSignalForAChildThatIsNoLongerTheOneStarted() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let real = try XCTUnwrap(ProcessTable.lookup(process.processIdentifier)?.identity)
        let stale = ProcessIdentity(pid: real.pid, startSeconds: real.startSeconds - 100, startMicros: 0)
        XCTAssertFalse(ProcessRunner.signalIfStillOurs(process, stale, SIGKILL), "start time differs: not ours")
        XCTAssertTrue(process.isRunning)
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        XCTAssertFalse(ProcessRunner.signalIfStillOurs(done, nil, SIGKILL), "a reaped child is never signalled")
    }

    func testTimeoutKillsOnlyThatProcess() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = try writeFakeTool(dir, name: "slow", body: "exec sleep 30")
        let started = Date()
        let output = try ProcessRunner.runBlocking(executable: slow, arguments: [], environment: [:], currentDirectory: nil, timeout: 0.5).get()
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }
}

final class SetupTests: XCTestCase {
    let document = """
    {
      "v": 1,
      "server_path": "/u/.local/bin/polybridge-server",
      "clients": [
        {"key": "claude-desktop", "available": true, "installed": true, "command": "/u/.local/bin/polybridge-server", "current": true, "action": null, "error": null, "notes": ["read /x"]},
        {"key": "opencode", "available": true, "installed": false, "command": null, "current": null, "action": "failed", "error": "no mcp remove", "notes": ["edit opencode.jsonc by hand"]},
        {"key": "vibe", "available": false, "installed": null, "command": null, "current": null, "action": null, "error": null, "notes": []}
      ]
    }
    """

    func testDecodesRowsRegardlessOfExitCode() throws {
        let decoded = try SetupDocument.decode(stdout: json(document), stderr: "", exitCode: 1).get()
        XCTAssertEqual(decoded.serverPath, "/u/.local/bin/polybridge-server")
        XCTAssertEqual(decoded.rows.map(\.key), ["claude-desktop", "opencode", "vibe"])
        XCTAssertEqual(decoded.rows[0].displayName, "Claude Desktop")
        XCTAssertEqual(decoded.rows[0].stateLabel, "Installed")
        XCTAssertEqual(decoded.rows[1].notes, ["edit opencode.jsonc by hand"])
        XCTAssertEqual(decoded.rows[1].error, "no mcp remove")
        XCTAssertNil(decoded.rows[2].installed)
        XCTAssertEqual(decoded.rows[2].stateLabel, "Unknown")
    }

    func testRefusesOtherVersions() {
        guard case .failure(.unsupportedVersion) = SetupDocument.decode(stdout: json(#"{"v": 2, "clients": []}"#), stderr: "", exitCode: 0) else { return XCTFail() }
        guard case .failure(.unsupportedCommand) = SetupDocument.decode(stdout: Data(), stderr: "error: unrecognized arguments: --json", exitCode: 2) else { return XCTFail() }
    }

    func testArguments() {
        XCTAssertEqual(SetupClient.arguments(.status, client: nil), ["--status", "--json"])
        XCTAssertEqual(SetupClient.arguments(.install, client: "codex"), ["--client=codex", "--json"])
        XCTAssertEqual(SetupClient.arguments(.remove, client: "codex"), ["--uninstall", "--client=codex", "--json"])
    }

    func testInstallAndRemoveRunOnlyTheFakeBinary() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log").path
        // A fake polybridge-setup: logs its argv and answers a v1 document naming the action.
        let setup = try writeFakeTool(dir, name: "polybridge-setup", body: """
        echo "$@" >> '\(log)'
        case "$1" in --uninstall) act=removed ;; --status) act=null ;; *) act=applied ;; esac
        [ "$act" = null ] || act="\\"$act\\""
        printf '{"v":1,"server_path":null,"clients":[{"key":"codex","available":true,"installed":true,"command":null,"current":null,"action":%s,"error":null,"notes":[]}]}' "$act"
        """)
        let client = SetupClient(executable: setup, environment: [:])
        let removed = try await client.perform(.remove, client: "codex").get()
        let installed = try await client.perform(.install, client: "codex").get()
        XCTAssertEqual(removed.rows.first?.action, "removed")
        XCTAssertEqual(installed.rows.first?.action, "applied")
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        XCTAssertEqual(calls, "--uninstall --client=codex --json\n--client=codex --json\n")
    }
}
