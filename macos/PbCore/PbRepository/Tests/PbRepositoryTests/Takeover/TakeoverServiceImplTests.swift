import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct TakeoverServiceImplTests {

    private func makeSUT(
        actions: MockTaskActionRepository = MockTaskActionRepository(),
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskList: MockTaskListRepository = MockTaskListRepository(),
        snapshots: MockTaskSnapshotRepository = MockTaskSnapshotRepository(),
        processRunner: any ProcessRunning = StubProcessRunner(output: stdout(""))
    ) -> TakeoverServiceImpl {
        given(taskList).refresh().willReturn()
        given(snapshots).refresh(.any).willReturn()
        return TakeoverServiceImpl(
            actions: actions, toolEnvironment: toolEnvironment, taskList: taskList,
            snapshots: snapshots, processRunner: processRunner
        )
    }

    // MARK: busy guard + locator failure

    @Test func givenATaskAlreadyBusy_whenBeginTakeoverIsCalled_thenTheCtlLocatorIsNeverAsked() {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn(["t1"])
        let toolEnvironment = MockToolEnvironmentRepository()
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment)

        // when
        sut.beginTakeover(taskID: "t1")

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
        sut.beginTakeover(taskID: "t1")

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
        sut.beginTakeover(taskID: "t1")

        // then
        verify(actions).setOutcome(.value("t1"), .value("Stopping the headless run and reserving the session…")).called(1)
    }

    // MARK: grant refusal (busy released after both refreshes — decision 4)

    @Test func givenTheGrantIsRefused_whenObserved_thenTheOutcomeIsTheErrorMessageAndBusyReleasesAfterBothRefreshes() async {
        // given
        let order = LockedBox<[String]>([])
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willProduce { _ in order.mutate { $0.append("endBusy") } }
        given(actions).takeover(.any, using: .any).willThrow(ToolError.refused(code: "session_busy", message: "already taken"))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { order.mutate { $0.append("list") } }
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willProduce { _ in order.mutate { $0.append("snapshot") } }
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshots)

        // when
        sut.beginTakeover(taskID: "t1")
        await waitUntil { order.value.count == 3 }

        // then — busy is released only after both refreshes.
        #expect(order.value == ["list", "snapshot", "endBusy"])
        verify(actions).setOutcome(.value("t1"), .matching { $0?.contains("already taken") == true }).called(1)
    }

    // MARK: Terminal.app hand-off

    @Test func givenTerminalAppOpenSucceeds_whenObserved_thenTheSuccessTextIsSet() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        let lastOutcome = LockedBox<String?>(nil)
        given(actions).setOutcome(.any, .any).willProduce { _, text in lastOutcome.mutate { $0 = text } }
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
        sut.beginTakeover(taskID: "t1")
        await waitUntil { lastOutcome.value?.contains("Opened in Terminal.app") == true }

        // then — never actually opened Terminal.app; the fake runner recorded the /usr/bin/open call.
        #expect(runner.calls.first?.executable == "/usr/bin/open")
        #expect(lastOutcome.value == "Opened in Terminal.app. It attaches itself before starting; if it cannot, it refuses to start the session.")
    }

    @Test func givenTerminalAppOpenFails_whenObserved_thenTheLapseTextIsSet() async {
        // given
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        let lastOutcome = LockedBox<String?>(nil)
        given(actions).setOutcome(.any, .any).willProduce { _, text in lastOutcome.mutate { $0 = text } }
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
        sut.beginTakeover(taskID: "t1")
        await waitUntil { lastOutcome.value?.contains("Terminal.app") == true }

        // then
        #expect(lastOutcome.value == "Terminal.app could not be opened. The takeover lapses unattached in 120 s.")
    }

    @Test func givenTheHandoffFilesCannotBeBuilt_whenObserved_thenTheWriteFailureTextIsSet() async {
        // given — an empty argv makes `TerminalAppHandoff.files` throw `BuildError.emptyArgv` before
        // anything is written or spawned, exercising the hand-off-write-failure branch deterministically.
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        let lastOutcome = LockedBox<String?>(nil)
        given(actions).setOutcome(.any, .any).willProduce { _, text in lastOutcome.mutate { $0 = text } }
        given(actions).endBusy(.any).willReturn()
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: [], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(
            .success(CtlClient(executable: "/opt/bin/polybridge-ctl", environment: [:], runner: StubProcessRunner(output: stdout(""))))
        )
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let runner = StubProcessRunner(output: stdout(""))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, processRunner: runner)

        // when
        sut.beginTakeover(taskID: "t1")
        await waitUntil { lastOutcome.value?.contains("hand-off could not be written") == true }

        // then — never even tried to open Terminal.app for a hand-off that could not be built.
        #expect(runner.calls.isEmpty)
        #expect(lastOutcome.value?.contains("The Terminal.app hand-off could not be written") == true)
    }

    // MARK: busy is always cleared, on every outcome

    @Test func givenEveryOutcome_whenBeginTakeoverCompletes_thenBusyIsAlwaysCleared() async {
        // given — the real repository, so `busy` reflects the actual atomic check-and-insert rather
        // than a mock's recorded calls.
        func run(taskID: String, ctl: Result<CtlClient, ToolError>, runner: any ProcessRunning) async {
            let toolEnvironment = MockToolEnvironmentRepository()
            given(toolEnvironment).ctl().willReturn(ctl)
            given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
            let taskList = MockTaskListRepository()
            given(taskList).refresh().willReturn()
            let snapshots = MockTaskSnapshotRepository()
            given(snapshots).refresh(.any).willReturn()
            let actions = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshots)
            let sut = TakeoverServiceImpl(actions: actions, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshots, processRunner: runner)

            sut.beginTakeover(taskID: taskID)
            await waitUntil { actions.busy.contains(taskID) == false && actions.outcome(taskID) != nil }
            #expect(actions.busy.contains(taskID) == false)
        }

        // locator failure — returns synchronously, never enters busy.
        await run(taskID: "locator-failure", ctl: .failure(.notFound(tool: "polybridge-ctl", searched: [])), runner: StubProcessRunner(output: stdout("")))

        // grant refused.
        let refusingRunner = StubProcessRunner { _ in .success(stdout(#"{"v":2,"error":{"code":"session_busy","message":"nope"}}"#)) }
        await run(
            taskID: "grant-refused", ctl: .success(CtlClient(executable: "/bin/echo", environment: [:], runner: refusingRunner)),
            runner: StubProcessRunner(output: stdout(""))
        )

        // Terminal.app open fails.
        let grantingRunner = StubProcessRunner { _ in .success(stdout(#"{"v":2,"result":{"argv":["claude"],"cwd":"/tmp"}}"#)) }
        await run(
            taskID: "open-fails", ctl: .success(CtlClient(executable: "/bin/echo", environment: [:], runner: grantingRunner)),
            runner: StubProcessRunner(output: ProcessOutput(exitCode: 1, stdout: Data(), stderr: "", timedOut: false))
        )

        // Terminal.app open succeeds.
        await run(
            taskID: "open-succeeds", ctl: .success(CtlClient(executable: "/bin/echo", environment: [:], runner: grantingRunner)),
            runner: StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: false))
        )
    }

    // MARK: duplicate takeover while busy is refused

    @Test func givenATakeoverAlreadyInFlight_whenBeginTakeoverIsCalledAgainForTheSameTask_thenTheSecondCallIsRefused() async {
        // given — the real repository so the busy set truly persists between the two calls.
        // `tryBeginBusy` runs synchronously inside `beginTakeover`, before the service-owned `Task`
        // that awaits the grant is even created, so the second call below is guaranteed to observe
        // the first call's busy state without needing to await anything in between.
        let toolEnvironment = MockToolEnvironmentRepository()
        let grantingRunner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"argv":["claude"],"cwd":"/tmp"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: grantingRunner)))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willReturn()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let actions = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskList, snapshotRepository: snapshots)
        let sut = TakeoverServiceImpl(
            actions: actions, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshots,
            processRunner: StubProcessRunner(output: stdout(""))
        )

        // when
        sut.beginTakeover(taskID: "t1")
        #expect(actions.busy.contains("t1"))
        sut.beginTakeover(taskID: "t1")

        // then — the second call never reached the locator a second time for this task: only one
        // "Stopping…" interim outcome was ever written.
        #expect(actions.outcome("t1") == "Stopping the headless run and reserving the session…")

        // cleanup — let the first call's own background Task finish before the test scope ends.
        await waitUntil { actions.busy.contains("t1") == false }
    }

    // MARK: refresh ordering — list before snapshot, even on success

    @Test func givenASuccessfulTakeover_whenObserved_thenTheListRefreshesBeforeTheSnapshot() async {
        // given
        let order = LockedBox<[String]>([])
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willReturn()
        given(actions).endBusy(.any).willProduce { _ in order.mutate { $0.append("endBusy") } }
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["claude"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { order.mutate { $0.append("list") } }
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willProduce { _ in order.mutate { $0.append("snapshot") } }
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: false))
        let sut = makeSUT(actions: actions, toolEnvironment: toolEnvironment, taskList: taskList, snapshots: snapshots, processRunner: runner)

        // when
        sut.beginTakeover(taskID: "t1")
        await waitUntil { order.value.count == 3 }

        // then
        #expect(order.value == ["list", "snapshot", "endBusy"])
    }

    // MARK: the handoff completes even if the requesting caller has gone

    @MainActor @Test func givenEveryReferenceToTheServiceIsDroppedRightAfterDispatching_whenTheTakeoverRuns_thenItStillCompletes() async {
        // given — the only owner of the service is the optional below, released immediately after
        // dispatching (a VM torn down right after calling it, with nothing else holding the service).
        // If the handoff's Task did not own the service, it would find it gone, never open Terminal,
        // never refresh, and leave the task stuck busy.
        let events = LockedBox<[String]>([])
        let actions = MockTaskActionRepository()
        given(actions).busy.willReturn([])
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).setOutcome(.any, .any).willProduce { _, text in
            if text?.hasPrefix("Opened in Terminal.app") == true { events.mutate { $0.append("opened") } }
        }
        given(actions).endBusy(.any).willProduce { _ in events.mutate { $0.append("endBusy") } }
        given(actions).takeover(.any, using: .any).willReturn(TakeoverGrant(argv: ["claude"], cwd: "/tmp", sessionID: nil, note: ""))
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout("")))))
        given(toolEnvironment).environment(toolDirectory: .any).willReturn([:])
        let taskList = MockTaskListRepository()
        given(taskList).refresh().willProduce { events.mutate { $0.append("list") } }
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willProduce { _ in events.mutate { $0.append("snapshot") } }
        let runner = StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: false))
        var sut: TakeoverServiceImpl? = TakeoverServiceImpl(
            actions: actions, toolEnvironment: toolEnvironment, taskList: taskList,
            snapshots: snapshots, processRunner: runner
        )
        weak var weakService = sut

        // when
        sut?.beginTakeover(taskID: "t1")
        sut = nil
        await waitUntil { events.value.contains("endBusy") }

        // then — the handoff ran to completion in order, and only then was the service released.
        #expect(events.value == ["opened", "list", "snapshot", "endBusy"])
        await waitUntil { weakService == nil }
        #expect(weakService == nil)
    }
}
