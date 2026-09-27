import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct TaskActionRepositoryImplTests {

    private func makeSUT(
        toolEnvironment: MockToolEnvironmentRepository = MockToolEnvironmentRepository(),
        taskListRepository: MockTaskListRepository = MockTaskListRepository(),
        snapshotRepository: MockTaskSnapshotRepository = MockTaskSnapshotRepository()
    ) -> TaskActionRepositoryImpl {
        given(taskListRepository).refresh().willReturn()
        given(snapshotRepository).refresh(.any).willReturn()
        return TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: snapshotRepository)
    }

    // MARK: tryBeginBusy — decision 4's atomic check-and-insert

    @Test func givenATaskNotBusy_whenTryBeginBusyIsCalled_thenItSucceedsAndMarksItBusy() {
        // given
        let sut = makeSUT()

        // when
        let began = sut.tryBeginBusy("t1")

        // then
        #expect(began == true)
        #expect(sut.busy.contains("t1"))
    }

    @Test func givenATaskAlreadyBusy_whenTryBeginBusyIsCalledAgain_thenItFails() {
        // given — the first call must actually have succeeded, or "the second call fails" would be
        // vacuously true against a stub that always returns `false`.
        let sut = makeSUT()
        let began = sut.tryBeginBusy("t1")
        #expect(began == true)

        // when
        let beganAgain = sut.tryBeginBusy("t1")

        // then
        #expect(beganAgain == false)
    }

    @Test func givenEndBusy_whenCalled_thenTheTaskCanBeBegunAgain() {
        // given
        let sut = makeSUT()
        sut.tryBeginBusy("t1")

        // when
        sut.endBusy("t1")

        // then
        #expect(sut.tryBeginBusy("t1") == true)
    }

    // MARK: perform semantics (F4-14/MS-ACTIONS-1)

    @Test func givenALocatorFailure_whenPerformingAnAction_thenBusyIsNeverSetTheOutcomeIsTheErrorMessageAndItThrows() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: ["/usr/local/bin"])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when / then — decision 3: the outcome is written before the rethrow, so it survives even
        // though this call throws.
        await #expect(throws: ToolError.self) {
            _ = try await sut.send("t1", text: "hi")
        }
        #expect(sut.busy.contains("t1") == false)
        #expect(sut.outcome("t1")?.contains("was not found") == true)
    }

    @Test func givenATaskAlreadyBusy_whenAnActionIsRequested_thenItReturnsFalseWithoutThrowingOrDoingAnything() async throws {
        // given — confirm the busy state was really reached before relying on it to reject the
        // action below.
        let toolEnvironment = MockToolEnvironmentRepository()
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        let began = sut.tryBeginBusy("t1")
        #expect(began == true)
        #expect(sut.busy.contains("t1"))

        // when — busy-rejected: never throws, and the return value is the documented "rejected"
        // signal (`false` for send/cancel, `nil` for resume).
        let attempted = try await sut.send("t1", text: "hi")

        // then — ctl() was never even asked, since the busy guard short-circuits first.
        #expect(attempted == false)
        verify(toolEnvironment).ctl().called(0)
        #expect(sut.outcome("t1") == nil)
    }

    @Test func givenResumeIsBusy_whenRequested_thenItReturnsNilWithoutThrowingOrDoingAnything() async throws {
        // given — confirm the busy state was really reached before relying on it to reject resume.
        let toolEnvironment = MockToolEnvironmentRepository()
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        let began = sut.tryBeginBusy("t1")
        #expect(began == true)
        #expect(sut.busy.contains("t1"))

        // when
        let onResumedCalled = LockedBox(false)
        let newID = try await sut.resume("t1", text: "hi") { _ in onResumedCalled.mutate { $0 = true } }

        // then
        #expect(newID == nil)
        verify(toolEnvironment).ctl().called(0)
        #expect(sut.outcome("t1") == nil)
        #expect(onResumedCalled.value == false)
    }

    @Test func givenAnAcceptedAction_whenItCompletes_thenItReturnsTrueAndBusyIsClearedThenOutcomeThenListThenSnapshotRefresh() async throws {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let taskListRepository = MockTaskListRepository()
        let snapshotRepository = MockTaskSnapshotRepository()
        var order: [String] = []
        let lock = NSLock()
        given(taskListRepository).refresh().willProduce { lock.lock(); order.append("list"); lock.unlock() }
        given(snapshotRepository).refresh(.any).willProduce { _ in lock.lock(); order.append("snapshot"); lock.unlock() }
        let sut = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: snapshotRepository)

        // when
        let attempted = try await sut.send("t1", text: "hi")

        // then
        #expect(attempted == true)
        #expect(sut.busy.contains("t1") == false)
        #expect(sut.outcome("t1") == "Queued — not yet delivered. The timeline shows it once the agent receives it.")
        #expect(order == ["list", "snapshot"])
    }

    // MARK: exact copy strings (F4-16/MS-ACTIONS-2)

    @Test func givenCancelSucceeds_whenObserved_thenTheOutcomeIsTheCascadeSummaryAndItReturnsTrue() async throws {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"status":"cancelled"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let attempted = try await sut.cancel("t1")

        // then
        #expect(attempted == true)
        #expect(sut.outcome("t1") == "Cancel sent · status cancelled")
    }

    @Test func givenCancelIsRefused_whenObserved_thenTheOutcomeIsTheRefusalAndItThrows() async {
        // given — the command itself refusing (not a locator failure) must also throw, after the
        // outcome is written.
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"error":{"code":"session_busy","message":"another run has it"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when / then
        await #expect(throws: ToolError.self) {
            _ = try await sut.cancel("t1")
        }
        #expect(sut.outcome("t1")?.isEmpty == false)
        #expect(sut.busy.contains("t1") == false)
    }

    @Test func givenResumeSucceeds_whenObserved_thenTheOutcomeNamesTheNewTaskAndReturnsItsID() async throws {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"task_id":"newtask123"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        let resumedID = LockedBox<String?>(nil)
        let newID = try await sut.resume("t1", text: "continue") { id in resumedID.mutate { $0 = id } }

        // then — F7: the repository returns the id; it never sets a selection itself.
        #expect(newID == "newtask123")
        #expect(sut.outcome("t1") == "Continued as task newtask1.")
        #expect(resumedID.value == "newtask123")
    }

    // Regression (item 4): the original (`AppModel.swift:291-299`) set the selection IMMEDIATELY
    // inside the work closure — before busy was released, the outcome written, or either refresh
    // ran. `onResumed` must fire at that exact point, not after this method has otherwise finished.
    @Test func givenResumeSucceeds_whenObserved_thenOnResumedFiresBeforeEndBusyAndBeforeBothRefreshes() async throws {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"task_id":"newtask123"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let taskListRepository = MockTaskListRepository()
        let snapshotRepository = MockTaskSnapshotRepository()
        let order = LockedBox<[String]>([])
        given(taskListRepository).refresh().willProduce { order.mutate { $0.append("list") } }
        given(snapshotRepository).refresh(.any).willProduce { _ in order.mutate { $0.append("snapshot") } }
        let sut = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: snapshotRepository)

        // when
        _ = try await sut.resume("t1", text: "continue") { _ in
            order.mutate { $0.append("onResumed") }
            // `endBusy` happens synchronously right after `onResumed` returns, inside `resume`
            // itself — not observable through a mock call, so the busy flag's own state at this
            // exact moment is the evidence that it has not run yet.
            order.mutate { $0.append(sut.busy.contains("t1") ? "stillBusy" : "notBusy") }
        }

        // then
        #expect(order.value == ["onResumed", "stillBusy", "list", "snapshot"])
    }

    @Test func givenASuspendingOnResumed_whenResumeSucceeds_thenItCompletesBeforeBusyIsReleasedAndTheRefreshesRun() async throws {
        // given — the original awaited `MainActor.run { selection = … }` before releasing busy, so
        // routing that has to hop actors must finish first, not merely be started.
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"task_id":"newtask123"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let taskListRepository = MockTaskListRepository()
        let snapshotRepository = MockTaskSnapshotRepository()
        let order = LockedBox<[String]>([])
        given(taskListRepository).refresh().willProduce { order.mutate { $0.append("list") } }
        given(snapshotRepository).refresh(.any).willProduce { _ in order.mutate { $0.append("snapshot") } }
        let sut = TaskActionRepositoryImpl(toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: snapshotRepository)

        // when
        _ = try await sut.resume("t1", text: "continue") { _ in
            await MainActor.run { order.mutate { $0.append("routed") } }
            await Task.yield()
            order.mutate { $0.append(sut.busy.contains("t1") ? "stillBusy" : "notBusy") }
        }

        // then
        #expect(order.value == ["routed", "stillBusy", "list", "snapshot"])
    }

    @Test func givenResumeFails_whenObserved_thenTheErrorIsThrownAndTheOutcomeIsTheErrorMessage() async {
        // given — decision 3: resume's own refusal is a genuine failure now, so it throws (nil is
        // reserved for "rejected because busy").
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"error":{"code":"no_session","message":"none"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when / then
        let onResumedCalled = LockedBox(false)
        await #expect(throws: ToolError.self) {
            _ = try await sut.resume("t1", text: "continue") { _ in onResumedCalled.mutate { $0 = true } }
        }
        #expect(sut.outcome("t1")?.isEmpty == false)
        #expect(onResumedCalled.value == false)
    }

    // MARK: cancelAll (F4-15)

    @Test func givenCancelAll_whenOneMemberIsAlreadyBusy_thenOnlyThatMemberIsSkipped() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"status":"cancelled"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = makeSUT(toolEnvironment: toolEnvironment)
        sut.tryBeginBusy("busy-one")

        // when
        await sut.cancelAll(["busy-one", "free-one"])

        // then
        #expect(sut.outcome("busy-one") == nil)
        #expect(sut.outcome("free-one") == "Cancel sent · status cancelled")
    }

    @Test func givenCancelAll_whenOneMemberIsRefused_thenTheOtherMembersStillComplete() async {
        // given — a `ctl()` that refuses for "refused-one" but succeeds for everyone else, so
        // "refused-one"'s `cancel` throws internally; `cancelAll` must not let that stop the rest.
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willProduce { () -> Result<CtlClient, ToolError> in
            let runner = StubProcessRunner { call in
                guard let taskID = call.arguments.last else { return .success(stdout(#"{"v":2,"result":{"status":"cancelled"}}"#)) }
                if taskID == "refused-one" {
                    return .success(stdout(#"{"v":2,"error":{"code":"session_busy","message":"nope"}}"#))
                }
                return .success(stdout(#"{"v":2,"result":{"status":"cancelled"}}"#))
            }
            return .success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner))
        }
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when
        await sut.cancelAll(["refused-one", "free-one"])

        // then — both were attempted; "refused-one"'s failure is visible in its own outcome, and
        // "free-one" completed normally regardless.
        #expect(sut.outcome("refused-one")?.isEmpty == false)
        #expect(sut.outcome("free-one") == "Cancel sent · status cancelled")
    }

    // MARK: run (F4-17 — throws to the caller, never writes an outcome)

    @Test func givenRunSucceeds_whenObserved_thenItRefreshesTheListingBeforeReturningTheID() async throws {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"task_id":"brandnew"}}"#))
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let taskListRepository = MockTaskListRepository()
        var refreshed = false
        given(taskListRepository).refresh().willProduce { refreshed = true }
        let sut = TaskActionRepositoryImpl(
            toolEnvironment: toolEnvironment, taskListRepository: taskListRepository, snapshotRepository: MockTaskSnapshotRepository()
        )

        // when
        let id = try await sut.run(RunRequest(backend: "claude", repo: "/tmp", prompt: "hi"))

        // then
        #expect(id == "brandnew")
        #expect(refreshed)
        #expect(sut.outcome("brandnew") == nil)
    }

    @Test func givenRunFails_whenObserved_thenTheErrorIsThrownNotWrittenToTheOutcomeLine() async {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.failure(.notFound(tool: "polybridge-ctl", searched: [])))
        let sut = makeSUT(toolEnvironment: toolEnvironment)

        // when / then
        await #expect(throws: (any Error).self) {
            _ = try await sut.run(RunRequest(backend: "claude", repo: "/tmp", prompt: "hi"))
        }
    }

    // MARK: takeover (raw — touches neither busy nor outcome)

    @Test func givenTakeoverSucceeds_whenObserved_thenBusyAndOutcomeAreUntouched() async throws {
        // given — `takeover(_:using:)` takes the caller's already-located client directly, so this
        // never goes through `toolEnvironment.ctl()` at all.
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"result":{"argv":["claude"],"cwd":"/tmp"}}"#))
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: runner)
        let sut = makeSUT()

        // when
        let grant = try await sut.takeover("t1", using: client)

        // then
        #expect(grant.argv == ["claude"])
        #expect(sut.busy.contains("t1") == false)
        #expect(sut.outcome("t1") == nil)
    }

    @Test func givenTakeoverFails_whenObserved_thenTheErrorIsThrownAndNeitherBusyNorOutcomeChange() async {
        // given — the failure comes from the passed-in client's own `takeover` call, not from a
        // locator (`takeover(_:using:)` never locates anything itself).
        let runner = StubProcessRunner(output: stdout(#"{"v":2,"error":{"code":"session_busy","message":"already taken"}}"#))
        let client = CtlClient(executable: "/bin/echo", environment: [:], runner: runner)
        let sut = makeSUT()

        // when / then
        await #expect(throws: (any Error).self) {
            _ = try await sut.takeover("t1", using: client)
        }
        #expect(sut.busy.contains("t1") == false)
        #expect(sut.outcome("t1") == nil)
    }

    @Test func givenManyConcurrentOutcomeWrites_whenTheyAllLand_thenNoOutcomeIsLost() async {
        // given — outcomes are written from the main actor and from background action tasks at once.
        let sut = makeSUT()
        let ids = (0 ..< 200).map { "task-\($0)" }

        // when
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { sut.setOutcome(id, "done \(id)") } }
        }

        // then
        #expect(ids.allSatisfy { sut.outcome($0) == "done \($0)" })
    }

    // MARK: - Outcome replay (piece 3: a copy outcome must survive leaving the task)

    @Test func givenAnOutcomeWasSetEarlier_whenANewSubscriberArrives_thenItReceivesTheStoredOutcome() {
        // given — the outcome is stored before anyone is listening (the detail screen was closed).
        let sut = makeSUT()
        sut.setOutcome("t1", "Copied resume command.")

        // when — a fresh subscriber (a new detail VM) subscribes afterwards
        var received: [[String: String]] = []
        let cancellable = sut.outcomesPublisher().sink { received.append($0) }
        cancellable.cancel()

        // then — it is replayed immediately, with nothing re-sent
        #expect(received.last?["t1"] == "Copied resume command.")
        #expect(sut.outcome("t1") == "Copied resume command.")
    }
}
