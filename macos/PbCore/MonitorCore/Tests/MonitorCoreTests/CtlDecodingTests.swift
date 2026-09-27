import Foundation
@testable import MonitorCore
import Testing

@Suite(.serialized)
struct CtlDecodingTests {
    func decode(_ text: String, stderr: String = "", exit: Int32 = 0, command: String = "list") -> Result<CtlDocument, ToolError> {
        CtlDocument.decode(stdout: json(text), stderr: stderr, exitCode: exit, command: command)
    }

    @Test
    func givenAListDocument_whenDecoded_thenBriefsAreReadLeniently() throws {
        // given
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
        // when
        guard case .success(.tasks(let tasks)) = result else { Issue.record("expected .tasks, got \(result)"); return }
        // then
        #expect(tasks.map(\.taskID) == ["a1", "old"])
        let first = tasks[0]
        #expect(first.backend == "claude")
        #expect(first.status == .running)
        #expect(first.liveInput)
        #expect(first.takenOver)
        #expect(first.maxDepth == 2)
        #expect(first.notices == ["n"])
        #expect(first.startedAt != nil, "microsecond isoformat must parse")
        #expect(first.isRoot)
        // A record from before lineage/live input existed still decodes, with safe defaults.
        #expect(tasks[1].backend == "unknown")
        #expect(!tasks[1].liveInput)
        #expect(!tasks[1].takenOver)
    }

    @Test
    func givenAStatusDocument_whenDecoded_thenSnapshotFieldsAreRead() {
        // given
        let result = decode("""
        {"v": 2, "task": {"task_id": "t", "status": "completed", "summary": "**done**", "exit_code": 0,
          "events_log": "/h/.polybridge/tasks/t.events.jsonl",
          "enforcement": {"commit_push_blocked": false, "direct_commit_commands_denied": true},
          "spawned_by": "p", "depth": 1, "resume_command": "cd /r && claude --resume s"}}
        """, command: "status")
        // when
        guard case .success(.task(let task)) = result else { Issue.record("expected .task, got \(result)"); return }
        // then
        #expect(task.status == .completed)
        #expect(task.summary == "**done**")
        #expect(task.exitCode == 0)
        #expect(task.enforcement?["direct_commit_commands_denied"] == .bool(true))
        #expect(!task.isRoot)
        #expect(task.resumeCommand == "cd /r && claude --resume s")
    }

    @Test
    func givenAResumeCommand_whenDecoded_thenNullAndEmptyAndWrongTypeAllReadAsNil() {
        // given / when / then — a null and an empty string both mean "nothing to offer", and a
        // non-string value (an older/corrupt document) must not crash the decode.
        guard case .success(.task(let withNull)) = decode(
            #"{"v": 2, "task": {"task_id": "t", "resume_command": null}}"#, command: "status"
        ) else { Issue.record("expected .task"); return }
        #expect(withNull.resumeCommand == nil)

        guard case .success(.task(let withEmpty)) = decode(
            #"{"v": 2, "task": {"task_id": "t", "resume_command": ""}}"#, command: "status"
        ) else { Issue.record("expected .task"); return }
        #expect(withEmpty.resumeCommand == nil)

        guard case .success(.task(let withWrongType)) = decode(
            #"{"v": 2, "task": {"task_id": "t", "resume_command": 7}}"#, command: "status"
        ) else { Issue.record("expected .task"); return }
        #expect(withWrongType.resumeCommand == nil)

        guard case .success(.task(let absent)) = decode(
            #"{"v": 2, "task": {"task_id": "t"}}"#, command: "status"
        ) else { Issue.record("expected .task"); return }
        #expect(absent.resumeCommand == nil)
    }

    @Test
    func givenAnErrorDocument_whenDecoded_thenItIsARefusalWithItsCode() {
        // given
        let result = decode(#"{"v": 2, "error": {"code": "descendants_not_stopped", "message": "task x survived"}}"#, exit: 1, command: "takeover")
        // when
        #expect(result == .success(.error(code: "descendants_not_stopped", message: "task x survived")))
        let failure = result.requiringSuccess()
        // then
        guard case .failure(let error) = failure else { Issue.record("expected .failure"); return }
        #expect(error.refusalCode == "descendants_not_stopped")
        #expect(error.message.contains("sub-task"), "\(error.message)")
        #expect(error.message.contains("task x survived"), "the ctl detail is kept: \(error.message)")
    }

    @Test
    func givenACallerUndecidableRefusal_whenReadItsMessage_thenItHasItsOwnExplanation() {
        // given
        let error = ToolError.refused(code: "caller_undecidable", message: "ps denied")
        // when / then
        #expect(error.message.contains("could not confirm"), "\(error.message)")
        #expect(error.message.contains("ps denied"))
    }

    @Test
    func givenAnUnknownRefusalCode_whenReadItsMessage_thenItFallsBackToTheMessage() {
        // given / when / then
        #expect(ToolError.refused(code: "brand_new", message: "why").message == "why (brand_new)")
    }

    @Test
    func givenAnUnknownOutcomeDocument_whenDecoded_thenItIsNotASuccess() {
        // given
        let result = decode(#"{"v": 2, "unknown": {"message": "check polybridge-ctl list"}}"#, exit: 3, command: "run")
        // when
        guard case .failure(.unknownOutcome(let message)) = result.requiringSuccess() else { Issue.record("expected .unknownOutcome"); return }
        // then
        #expect(message == "check polybridge-ctl list")
    }

    @Test
    func givenAnUnsupportedSchemaVersion_whenDecoded_thenItIsRefused() {
        // given / when — v3 is genuinely outside `ctlContractVersions` ({1, 2}).
        guard case .failure(.unsupportedVersion(_, let v)) = decode(#"{"v": 3, "tasks": []}"#) else { Issue.record("expected .unsupportedVersion"); return }
        // then
        #expect(v == "3")
        #expect(ToolError.unsupportedVersion(tool: "polybridge-ctl", version: "3").message.contains("understands versions 1 or 2"))
        guard case .failure(.unsupportedVersion(_, let none)) = decode(#"{"tasks": []}"#) else { Issue.record("expected .unsupportedVersion"); return }
        #expect(none == "none")
    }

    @Test
    func givenEitherCtlContractVersion_whenDecoded_thenBothAreAccepted() {
        // given / when / then — v2 added `resume_command` (Monitor piece 3/3); v1 records simply
        // have none, so both stay readable.
        #expect(ctlContractVersions == [1, 2])
        guard case .success(.tasks) = decode(#"{"v": 1, "tasks": []}"#) else { Issue.record("v1 should decode"); return }
        guard case .success(.tasks) = decode(#"{"v": 2, "tasks": []}"#) else { Issue.record("v2 should decode"); return }
    }

    @Test
    func givenAnOldCtlWithNoTakeoverSubcommand_whenDecoded_thenTheMissingSubcommandIsRecognised() {
        // given / when
        // The new ctl answers a usage error as JSON...
        let jsonUsage = decode(
            #"{"v": 1, "error": {"code": "usage", "message": "argument command: invalid choice: 'takeover' (choose from list, status)"}}"#,
            exit: 2, command: "takeover"
        )
        guard case .failure(.unsupportedCommand(_, let command, _)) = jsonUsage else { Issue.record("expected .unsupportedCommand, got \(jsonUsage)"); return }
        // then
        #expect(command == "takeover")
        // ...an older one only in prose on stderr.
        let prose = decode("", stderr: "polybridge-ctl: error: argument command: invalid choice: 'send'", exit: 2, command: "send")
        guard case .failure(let error) = prose, case .unsupportedCommand = error else { Issue.record("expected .unsupportedCommand, got \(prose)"); return }
        #expect(error.message.contains("predates"), "\(error.message)")
    }

    @Test
    func givenUnparsableOutput_whenDecoded_thenItIsUnreadable() {
        // given / when
        guard case .failure(.unreadable(_, 1, let stderr)) = decode("Traceback...", stderr: "boom", exit: 1) else {
            Issue.record("expected .unreadable")
            return
        }
        // then
        #expect(stderr == "boom")
    }

    @Test
    func givenRawStatusStrings_whenParsedAsTaskStatus_thenLabelsAndTerminalityMatch() {
        // given / when / then
        #expect(TaskStatus("timed_out") == .timedOut)
        #expect(TaskStatus("weird") == .other("weird"))
        #expect(TaskStatus("cancelled").isTerminal)
        #expect(!TaskStatus("weird").isTerminal)
    }

    @Test
    func givenTakeoverGrantJSON_whenDecoded_thenItRequiresAStringArgvAndCwd() {
        // given / when / then
        #expect(TakeoverGrant(["argv": .array([]), "cwd": .string("/r")]) == nil)
        #expect(TakeoverGrant(["argv": .array([.string("/x"), .number(1)]), "cwd": .string("/r")]) == nil)
        #expect(TakeoverGrant(["argv": .array([.string("/x")])]) == nil)
        let grant = TakeoverGrant([
            "argv": .array([.string("/bin/claude"), .string("--resume"), .string("s1")]), "cwd": .string("/r"),
            "session_id": .string("s1"), "note": .string("n")
        ])
        #expect(grant?.argv == ["/bin/claude", "--resume", "s1"])
    }
}

@Suite(.serialized)
struct CtlClientTests {
    @Test
    func givenCommandsWithOptionsAndPositionals_whenBuildingArgv_thenOptionsComeBeforeJsonAndPositionalsAfterTheSeparator() {
        // given / when / then
        #expect(CtlClient.argv("list") == ["list", "--json"])
        #expect(CtlClient.argv("send", positionals: ["t1", "-rf everything"]) == ["send", "--json", "--", "t1", "-rf everything"])
        #expect(CtlClient.argv("takeover-attach", options: ["--pid=42"], positionals: ["t1"]) == ["takeover-attach", "--pid=42", "--json", "--", "t1"])
    }

    @Test
    func givenARunRequest_whenBuildingArguments_thenItUsesTheEqualsForm() {
        // given
        let request = RunRequest(backend: "claude", repo: "/r", prompt: "--max-turns 1", freedom: "read_only", group: "g")
        // when / then
        #expect(request.arguments == ["--backend=claude", "--repo=/r", "--prompt=--max-turns 1", "--freedom=read_only", "--group=g"])
    }

    @Test
    func givenEachClientCommand_whenSent_thenItProducesTheExpectedArgv() async throws {
        // given
        let runner = RecordingRunner { call in
            switch call.arguments.first {
            case "takeover":
                ProcessOutput(
                    exitCode: 0, stdout: json(#"{"v":2,"result":{"argv":["/c","--resume","s"],"cwd":"/r","session_id":"s","note":"n"}}"#),
                    stderr: ""
                )
            case "run", "resume": ProcessOutput(exitCode: 0, stdout: json(#"{"v":2,"result":{"task_id":"new1"}}"#), stderr: "")
            default: ProcessOutput(exitCode: 0, stdout: json(#"{"v":2,"result":{"status":"queued"}}"#), stderr: "")
            }
        }
        let client = CtlClient(executable: "/fake/polybridge-ctl", environment: ["PB_OPEN_MONITOR": "0"], runner: runner)
        // when
        _ = await client.send("t1", text: "hi")
        _ = await client.cancel("t1")
        let grant = await client.takeover("t1")
        let started = await client.run(RunRequest(backend: "codex", repo: "/r", prompt: "p"))
        let resumed = await client.resume("t1", text: "more")
        // then
        try #expect(try grant.get().argv == ["/c", "--resume", "s"])
        try #expect(try started.get() == "new1")
        try #expect(try resumed.get() == "new1")
        #expect(runner.calls.map(\.arguments) == [
            ["send", "--json", "--", "t1", "hi"],
            ["cancel", "--json", "--", "t1"],
            ["takeover", "--json", "--", "t1"],
            ["run", "--backend=codex", "--repo=/r", "--prompt=p", "--json"],
            ["resume", "--json", "--", "t1", "more"]
        ])
        #expect(runner.calls.allSatisfy { $0.environment["PB_OPEN_MONITOR"] == "0" })
    }

    @Test
    func givenARealFakeBinary_whenListed_thenItsArgvAndEnvironmentReachTheChild() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Echoes its argv back inside a v2 list document, and proves PB_OPEN_MONITOR arrived.
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: """
        printf '{"v":2,"tasks":[{"task_id":"t-%s","backend":"%s","status":"running"}]}\\n' "$#" "$PB_OPEN_MONITOR"
        """)
        let env = LaunchEnvironment.build(base: ["PATH": "/usr/bin:/bin", "PB_TASK_ID": "leak"], loginPath: nil, toolDirectory: dir.path)
        // when
        let tasks = try await CtlClient(executable: ctl, environment: env).list().get()
        // then
        #expect(tasks.map(\.taskID) == ["t-2"], "argv was `list --json`")
        #expect(tasks.first?.backend == "0", "PB_OPEN_MONITOR=0 reached the child")
    }

    @Test
    func givenAFakeBinaryOnAnUnknownVersion_whenListed_thenItDegrades() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ctl = try writeFakeTool(dir, name: "polybridge-ctl", body: #"echo '{"v": 7, "tasks": []}'"#)
        // when
        let result = await CtlClient(executable: ctl, environment: [:]).list()
        // then
        guard case .failure(let error) = result, case .unsupportedVersion = error else { Issue.record("expected .unsupportedVersion, got \(result)"); return }
        #expect(error.message.contains("version 7"), "\(error.message)")
    }

    @Test
    func givenAMissingBinary_whenListed_thenItIsALaunchFailure() async {
        // given / when
        let result = await CtlClient(executable: "/nonexistent/polybridge-ctl", environment: [:]).list()
        // then
        guard case .failure(.launchFailed) = result else { Issue.record("expected .launchFailed, got \(result)"); return }
    }

    @Test
    func givenAChildThatIgnoresSigterm_whenItTimesOut_thenItEscalatesToSigkill() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let stubborn = try writeFakeTool(dir, name: "stubborn", body: "trap '' TERM; while :; do sleep 1; done")
        let started = Date()
        // when
        let output = try ProcessRunner.runBlocking(executable: stubborn, arguments: [], environment: [:], currentDirectory: nil, timeout: 0.5).get()
        // then
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }

    @Test
    func givenAProcessThatIsNoLongerTheOneStarted_whenSignalled_thenNoSignalIsSent() throws {
        // given
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate(); process.waitUntilExit() }
        let real = try #require(ProcessTable.lookup(process.processIdentifier)?.identity)
        let stale = ProcessIdentity(pid: real.pid, startSeconds: real.startSeconds - 100, startMicros: 0)
        // when / then
        #expect(!ProcessRunner.signalIfStillOurs(process, stale, SIGKILL), "start time differs: not ours")
        #expect(process.isRunning)
        let done = Process()
        done.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try done.run()
        done.waitUntilExit()
        #expect(!ProcessRunner.signalIfStillOurs(done, nil, SIGKILL), "a reaped child is never signalled")
    }

    @Test
    func givenASlowProcess_whenItTimesOut_thenOnlyThatProcessIsKilled() throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let slow = try writeFakeTool(dir, name: "slow", body: "exec sleep 30")
        let started = Date()
        // when
        let output = try ProcessRunner.runBlocking(executable: slow, arguments: [], environment: [:], currentDirectory: nil, timeout: 0.5).get()
        // then
        #expect(output.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

@Suite(.serialized)
struct SetupTests {
    let document = """
    {
      "v": 1,
      "server_path": "/u/.local/bin/polybridge-server",
      "clients": [
        {
            "key": "claude-desktop", "available": true, "installed": true, "command": "/u/.local/bin/polybridge-server",
            "current": true, "action": null, "error": null, "notes": ["read /x"]
        },
        {
            "key": "opencode", "available": true, "installed": false, "command": null, "current": null,
            "action": "failed", "error": "no mcp remove", "notes": ["edit opencode.jsonc by hand"]
        },
        {"key": "vibe", "available": false, "installed": null, "command": null, "current": null, "action": null, "error": null, "notes": []}
      ]
    }
    """

    @Test
    func givenASetupDocument_whenDecoded_thenRowsAreReadRegardlessOfExitCode() throws {
        // given / when
        let decoded = try SetupDocument.decode(stdout: json(document), stderr: "", exitCode: 1).get()
        // then
        #expect(decoded.serverPath == "/u/.local/bin/polybridge-server")
        #expect(decoded.rows.map(\.key) == ["claude-desktop", "opencode", "vibe"])
        #expect(decoded.rows[0].displayName == "Claude Desktop")
        #expect(decoded.rows[0].stateLabel == "Installed")
        #expect(decoded.rows[1].notes == ["edit opencode.jsonc by hand"])
        #expect(decoded.rows[1].error == "no mcp remove")
        #expect(decoded.rows[2].installed == nil)
        #expect(decoded.rows[2].stateLabel == "Unknown")
    }

    @Test
    func givenUnsupportedSetupOutput_whenDecoded_thenItIsRefused() {
        // given / when / then
        guard case .failure(.unsupportedVersion) = SetupDocument.decode(stdout: json(#"{"v": 2, "clients": []}"#), stderr: "", exitCode: 0) else {
            Issue.record("expected .unsupportedVersion")
            return
        }
        guard case .failure(.unsupportedCommand) = SetupDocument.decode(stdout: Data(), stderr: "error: unrecognized arguments: --json", exitCode: 2) else {
            Issue.record("expected .unsupportedCommand")
            return
        }
    }

    @Test
    func givenSetupActions_whenBuildingArguments_thenTheyMatchTheAction() {
        // given / when / then
        #expect(SetupClient.arguments(.status, client: nil) == ["--status", "--json"])
        #expect(SetupClient.arguments(.install, client: "codex") == ["--client=codex", "--json"])
        #expect(SetupClient.arguments(.remove, client: "codex") == ["--uninstall", "--client=codex", "--json"])
    }

    @Test
    func givenAFakeSetupBinary_whenInstallingAndRemoving_thenOnlyTheFakeBinaryRuns() async throws {
        // given
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = dir.appendingPathComponent("calls.log").path
        // A fake polybridge-setup: logs its argv and answers a v1 document naming the action.
        let setup = try writeFakeTool(dir, name: "polybridge-setup", body: """
        echo "$@" >> '\(log)'
        case "$1" in --uninstall) act=removed ;; --status) act=null ;; *) act=applied ;; esac
        [ "$act" = null ] || act="\\"$act\\""
        printf '{"v":1,"server_path":null,"clients":[{"key":"codex","available":true,"installed":true,"command":null,"current":null,'\
        '"action":%s,"error":null,"notes":[]}]}' "$act"
        """)
        let client = SetupClient(executable: setup, environment: [:])
        // when
        let removed = try await client.perform(.remove, client: "codex").get()
        let installed = try await client.perform(.install, client: "codex").get()
        // then
        #expect(removed.rows.first?.action == "removed")
        #expect(installed.rows.first?.action == "applied")
        let calls = try String(contentsOfFile: log, encoding: .utf8)
        #expect(calls == "--uninstall --client=codex --json\n--client=codex --json\n")
    }
}
