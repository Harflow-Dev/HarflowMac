import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
@testable import PbTerminal
import PbTestUtilities
import Testing

@MainActor
@Suite(.serialized)
struct TakeoverServiceImplTests {

    private func makeSUT(
        actions: MockTaskActionRepository = MockTaskActionRepository(),
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskList: MockTaskListRepository = MockTaskListRepository(),
        snapshots: MockTaskSnapshotRepository = MockTaskSnapshotRepository(),
        registry: MockTerminalSessionRegistry = MockTerminalSessionRegistry(),
        processRunner: any ProcessRunning = StubProcessRunner(output: stdout(""))
    ) -> TakeoverServiceImpl {
        given(taskList).refresh().willReturn()
        given(taskList).title(.any).willReturn("Task abcdef12")
        given(taskList).task(.any).willReturn(nil)
        given(snapshots).refresh(.any).willReturn()
        given(registry).add(.any).willReturn()
        return TakeoverServiceImpl(
            actions: actions, toolEnvironment: toolEnvironment, taskList: taskList,
            snapshots: snapshots, registry: registry, processRunner: processRunner
        )
    }

    // MARK: busy guard + locator failure (MS-ACTIONS-4/F3)

    @Test func givenATaskAlreadyBusy_whenBeginTakeoverIsCalled_thenTheCtlLocatorIsNeverAsked() {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn(["t1"])
        let toolEnvironment = MockToolEnvironmentRepository()
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)

        // then — the busy check really ran (rules out a no-op `beginTakeover`, which would also
        // leave ctl/setOutcome untouched and vacuously pass the checks below)...
        verify(actions).busy.called(1)
        verify(actions).tryBeginBusy(.any).called(0)
        // ...and, having failed it, nothing else happens.
        verify(toolEnvironment).ctl().called(0)
        verify(actions).setOutcome(.any, .any).called(0)
    }

    @Test func givenACtlLocateFailure_whenBeginTakeoverIsCalled_thenTheOutcomeIsTheErrorMessageAndBusyIsNeverEntered() {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willReturn()
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: ["/usr/local/bin"])))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)

        // then — synchronous: no Task is even dispatched on a locator failure.
        verify(actions).busy.called(1)
        verify(actions).setOutcome(.value("t1"), .matching { $0?.contains("was not found") == true }).called(1)
        verify(actions).tryBeginBusy(.any).called(0)
        verify(actions).endBusy(.any).called(0)
        verify(actions).takeover(.any, using: .any).called(0)
    }

    @Test func givenCtlSucceeds_whenBeginTakeoverIsCalled_thenTheInterimOutcomeIsSetImmediately() {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: [], cwd: "", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment)

        // when — `setOutcome` for the interim text runs synchronously, before the service-owned
        // `Task` that awaits the grant is even created, so this needs no `await`/polling to observe.
        sut.beginTakeover(taskID: "t1", destination: .embedded)

        // then
        verify(actions).setOutcome(.value("t1"), .value("Stopping the headless run and reserving the session…")).called(1)
    }

    // MARK: grant refusal (busy released after both refreshes — decision 4)

    @Test func givenTheGrantIsRefused_whenObserved_thenTheOutcomeIsTheErrorMessageAndBusyReleasesAfterBothRefreshes() async {
        // given
        let order = OrderRecorder()
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willProduce { _ in order.record("endBusy") }
        given(actions).takeover(.any, using: .any).willThrow(ToolError.refused(code: "session_busy", message: "already taken"))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { order.record("list") }
        given(taskList).title(.any).willReturn("t")
        given(taskList).task(.any).willReturn(nil)
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willProduce { _ in order.record("snapshot") }
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshots)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)
        await waitUntil { order.order.count == 3 }

        // then — busy is released only after both refreshes, matching the `defer` at AppModel.swift:335
        // wrapping the whole task body.
        #expect(order.order == ["list", "snapshot", "endBusy"])
        verify(actions).setOutcome(.value("t1"), .matching { $0?.contains("already taken") == true }).called(1)
    }

    // MARK: wrapper failure (deterministic — no process spawn)

    @Test func givenAnEmptyGrantArgv_whenEmbeddedTakeoverBuildsItsCommand_thenTheExactWrapperFailureTextIsSet() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        var outcomes: [String?] = []
        given(actions).setOutcome(.any, .any).willProduce { _, text in outcomes.append(text) }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: [], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let registry = MockTerminalSessionRegistry()
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, registry: registry)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)
        await waitUntil { outcomes.contains { $0?.contains("could not be started") == true } }

        // then — `waitUntil` never fails on timeout by itself, so the wrapper-build failure text
        // must be asserted explicitly here, or a `beginTakeover` that silently did nothing would
        // vacuously pass this test too (the "no session created" check below holds in both cases).
        #expect(outcomes.contains { $0?.contains("could not be started") == true })
        // ...and no session was ever created for an argv that cannot build a wrapper command.
        verify(registry).add(.any).called(0)
    }

    // MARK: embedded, real process (F4-18/MS-ACTIONS-4) — spawns /bin/cat directly, no TakeoverWrapper login-shell overhead

    @Test func givenEmbeddedTakeover_whenBuildingItsCommand_thenNoToolDirectoryOverrideIsApplied() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willReturn()
        given(actions).takeoverAttach(.any, pid: .any, using: .any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["/bin/cat"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .value(nil)).willReturn(["PATH": "/usr/bin"])
        var addedSession: TerminalSession?
        let registry = MockTerminalSessionRegistry()
        given(registry).add(.any).willProduce { addedSession = $0 }
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, registry: registry)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)
        await waitUntil { addedSession?.pid != nil }
        // `addedSession?.terminate { ... }` below would silently no-op on a `nil` session (optional
        // chaining), which would never resume the continuation and hang the test forever instead of
        // failing it — guard explicitly so a regression here fails loudly.
        guard let session = addedSession else {
            Issue.record("expected a session to have been added and started")
            return
        }

        // then — F4-18's exact requirement: `environment()` (no tool-directory override) built the
        // wrapper's environment.
        verify(toolEnvironment).environment(toolDirectory: .value(nil)).called(1)

        // cleanup: never leave a real `cat` running past this test.
        await withCheckedContinuation { continuation in
            session.terminate { _ in continuation.resume() }
        }
    }

    @Test func givenEmbeddedAttachSucceeds_whenObserved_thenAttachedIsTrueAndTheOutcomeClears() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        var lastOutcome: String??
        given(actions)
.setOutcome(.any, .any)
.willProduce { _, text in lastOutcome = text }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeoverAttach(.any, pid: .any, using: .any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["/bin/cat"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        var addedSession: TerminalSession?
        let registry = MockTerminalSessionRegistry()
        given(registry).add(.any).willProduce { addedSession = $0 }
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, registry: registry)

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)
        await waitUntil { addedSession?.attached == true }
        // Same guard as `givenEmbeddedTakeover_whenBuildingItsCommand_thenNoToolDirectoryOverrideIsApplied`:
        // a `nil` session would otherwise no-op the cleanup below and hang instead of failing.
        guard let session = addedSession else {
            Issue.record("expected a session to have been added and attached")
            return
        }

        // then
        #expect(session.attached == true)
        #expect(lastOutcome == .some(.none))

        // cleanup
        await withCheckedContinuation { continuation in
            session.terminate { _ in continuation.resume() }
        }
    }

    @Test func givenEmbeddedAttachIsRefused_whenObserved_thenTheTerminalIsTerminatedAndTheOutcomeNamesTheRefusal() async {
        // given
        let refusal = ToolError.refused(code: "unknown_task", message: "gone")
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        let outcomes = ValueRecorder<String?>()
        given(actions).setOutcome(.any, .any).willProduce { _, text in outcomes.append(text) }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeoverAttach(.any, pid: .any, using: .any).willThrow(refusal)
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["/bin/cat"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        var addedSession: TerminalSession?
        let registry = MockTerminalSessionRegistry()
        given(registry).add(.any).willProduce { addedSession = $0 }
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, registry: registry)

        // when — every hop of this flow (`Task { [weak self] ... }`, `onStarted`'s Task, `terminate`'s
        // completion) captures the service only weakly, matching production, where the real service
        // is a long-lived singleton nothing needs to keep alive on purpose. Wrapping the whole thing
        // in one `Task` that captures `sut` directly (no `weak`) stands in for that ownership across
        // the async window this test spans.
        //
        // Poll the outcome *count*, not `session.ended`: SwiftTerm's own SIGCHLD-based exit
        // detection reliably wins the race against `ChildReaper.terminate`'s polling confirmation
        // (`usleep`-based, 50 ms ticks) — `/bin/cat` receiving `ChildReaper`'s SIGHUP already flips
        // `ended` before `ChildReaper` itself has finished confirming the process is gone and calling
        // this method's own `terminate(completion:)` callback. Waiting on `ended` therefore returns
        // before the third `setOutcome` call this test is actually about, and was verified by
        // instrumenting both callbacks directly: `ended` (and its `WaitStatus.signalled(1)`, i.e.
        // SIGHUP) is observed before "terminate completion fired" ever prints.
        let snapshot = await Task { () async -> [String?] in
            sut.beginTakeover(taskID: "t1", destination: .embedded)
            await waitUntil(timeout: 8) { outcomes.snapshot().count >= 3 }
            return outcomes.snapshot()
        }.value

        // then — `ToolError.refused`'s own `.message` prepends a code-specific headline
        // (`TakeoverRefusal.explanation`) ahead of the raw ctl text, so the expected string is built
        // from that same property rather than hand-guessed.
        #expect(snapshot.count == 3)
        #expect(snapshot.last == "The terminal was closed because the takeover could not be attached: \(refusal.message)")
        #expect(addedSession?.ended == true)
    }

    // MARK: the four attach-failure texts, as a pure function (deterministic, no process spawn)

    @Test func givenEachTerminateOutcome_whenMappedToAMessage_thenTheFourTextsMatchExactly() {
        #expect(
            TakeoverServiceImpl.attachFailureOutcomeMessage(.stopped, attachMessage: "nope")
                == "The terminal was closed because the takeover could not be attached: nope"
        )
        #expect(
            TakeoverServiceImpl.attachFailureOutcomeMessage(.alreadyGone, attachMessage: "nope")
                == "The terminal was closed because the takeover could not be attached: nope"
        )
        #expect(
            TakeoverServiceImpl.attachFailureOutcomeMessage(.survived([111, 222]), attachMessage: "nope")
                == "The takeover could not be attached and these processes would not exit — end them yourself: 111, 222. nope"
        )
        #expect(
            TakeoverServiceImpl.attachFailureOutcomeMessage(.unconfirmed(pids: [], reason: "table unreadable"), attachMessage: "nope")
                == "The takeover could not be attached, and the terminal could not be confirmed closed (table unreadable). nope"
        )
        #expect(
            TakeoverServiceImpl.attachFailureOutcomeMessage(.unconfirmed(pids: [42], reason: "table unreadable"), attachMessage: "nope")
                == "The takeover could not be attached, and the terminal could not be confirmed closed (table unreadable) — check: 42. nope"
        )
    }

    // MARK: Terminal.app hand-off (F4-19/MS-TERM-6 wiring — texts already pinned in MonitorCoreTests)

    @Test func givenTerminalAppOpenSucceeds_whenObserved_thenTheSuccessTextIsSet() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        var lastOutcome: String?
        given(actions)
.setOutcome(.any, .any)
.willProduce { _, text in lastOutcome = text }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["claude"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(
            .success(CtlClient(executable: "/opt/bin/polybridge-ctl", environment: [:], runner: StubProcessRunner(output: stdout(""))))
        )
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: false))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, processRunner: runner)

        // when
        sut.beginTakeover(taskID: "t1", destination: .terminalApp)
        await waitUntil { lastOutcome?.contains("Opened in Terminal.app") == true }

        // then — never actually opened Terminal.app; the fake runner recorded the /usr/bin/open call.
        #expect(runner.calls.first?.executable == "/usr/bin/open")
        #expect(lastOutcome == "Opened in Terminal.app. It attaches itself before starting; if it cannot, it refuses to start the session.")
    }

    @Test func givenTerminalAppOpenFails_whenObserved_thenTheLapseTextIsSet() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        var lastOutcome: String?
        given(actions)
.setOutcome(.any, .any)
.willProduce { _, text in lastOutcome = text }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["claude"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(
            .success(CtlClient(executable: "/opt/bin/polybridge-ctl", environment: [:], runner: StubProcessRunner(output: stdout(""))))
        )
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 1, stdout: Data(), stderr: "no Terminal", timedOut: false))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, processRunner: runner)

        // when — poll for the *final* text specifically: the interim "Stopping…" message also
        // satisfies a bare `!= nil` check, since it is written synchronously before this ever runs.
        sut.beginTakeover(taskID: "t1", destination: .terminalApp)
        await waitUntil { lastOutcome?.contains("Terminal.app") == true }

        // then
        #expect(lastOutcome == "Terminal.app could not be opened. The takeover lapses unattached in 120 s.")
    }

    // MARK: item 2 — the grant and the attach must use the ONE located client (AppModel.swift:325-362)

    /// A real `TaskActionRepositoryImpl` (not a mock), so a client re-located deep inside
    /// `takeover`/`takeoverAttach` is actually observable — the mock used everywhere else in this
    /// file bypasses that locating logic entirely. `toolEnvironment.ctl()` is stubbed to hand back a
    /// *different* `CtlClient` on each call; if `beginTakeover`'s grant or the embedded attach ever
    /// re-located instead of reusing the client captured at the top of `beginTakeover`, the two
    /// steps would be served by different clients.
    @Test func givenTheLocatorWouldReturnADifferentClientOnEachCall_whenBeginTakeoverRunsEmbedded_thenTheGrantAndTheAttachUseTheSameLocatedClient() async {
        // given
        let recorder = ValueRecorder<String>()
        func respondingClient(label: String) -> CtlClient {
            let runner = StubProcessRunner { call in
                let command = call.arguments.first ?? "?"
                recorder.append("\(command)=\(label)")
                if command == "takeover-attach" { return .success(stdout(#"{"v":1,"result":{}}"#)) }
                return .success(stdout(#"{"v":1,"result":{"argv":["/bin/cat"],"cwd":"/tmp"}}"#))
            }
            return CtlClient(executable: "/\(label)", environment: [:], runner: runner)
        }
        let clientA = respondingClient(label: "client-A")
        let clientB = respondingClient(label: "client-B")
        let clientC = respondingClient(label: "client-C")
        let callCount = OrderRecorder()
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willProduce { () -> Result<CtlClient, ToolError> in
            callCount.record("call")
            switch callCount.order.count {
            case 1: return .success(clientA)
            case 2: return .success(clientB)
            default: return .success(clientC)
            }
        }
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willReturn()
        given(taskList).title(.any).willReturn("t")
        given(taskList).task(.any).willReturn(nil)
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        // The real repository — see the doc comment above for why the mock cannot exercise this bug.
        let actions = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshots)
        var addedSession: TerminalSession?
        let registry = MockTerminalSessionRegistry()
        given(registry).add(.any).willProduce { addedSession = $0 }
        let sut = TakeoverServiceImpl(
            actions: actions, toolEnvironment: toolEnvironment, taskList: taskList,
            snapshots: snapshots, registry: registry, processRunner: StubProcessRunner(output: stdout(""))
        )

        // when
        sut.beginTakeover(taskID: "t1", destination: .embedded)
        await waitUntil { addedSession?.attached == true }
        guard let session = addedSession else {
            Issue.record("expected a session to have been added and attached")
            return
        }

        // then — exactly one locate happened (`beginTakeover`'s own), and both the grant and the
        // attach were served by that same client.
        #expect(callCount.order.count == 1)
        let takeoverClient = recorder.snapshot().first { $0.hasPrefix("takeover=") }
        let attachClient = recorder.snapshot().first { $0.hasPrefix("takeover-attach=") }
        #expect(takeoverClient == "takeover=client-A")
        #expect(attachClient == "takeover-attach=client-A")

        // cleanup
        await withCheckedContinuation { continuation in
            session.terminate { _ in continuation.resume() }
        }
    }
}
