import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

// MARK: - Outcome inspection

private extension TaskChangesReadFailure {
    /// The tool error of a failed (not superseded) read.
    var error: ToolError? {
        if case .failed(let error) = outcome { error } else { nil }
    }

    var isSuperseded: Bool { outcome == .superseded }

    /// The client bound of a read that stopped at its own limit.
    var clientBound: ClientBound? {
        if case .clientBound(let bound) = outcome { bound } else { nil }
    }

    /// The `unreadable` detail of a failed read.
    var detail: String? {
        if case .unreadable(_, _, let stderr)? = error { stderr } else { nil }
    }
}

private actor StartLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

// MARK: - TaskChangesRepositoryTests

struct TaskChangesRepositoryTests {
    private static let key = TaskChangesKey(taskID: "task", generation: 7)
    private static let secret = "SECRET-DIFF-TOKEN-4711"
    private static let selector = TaskChangesSelector(repositoryRoot: "/workspace/repo", scope: .workingTree, pathBytes: Data("a.txt".utf8))!

    private func listing(_ harness: ChangesHarness, current: @escaping @Sendable () -> Bool = { true })
        async -> Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure> {
        await harness.repository.readListing(key: Self.key, operationIsCurrent: current)
    }

    private func patch(_ harness: ChangesHarness, current: @escaping @Sendable () -> Bool = { true })
        async -> Result<TaskChangesRead<TaskChangesPatch>, TaskChangesReadFailure> {
        await harness.repository.readPatch(key: Self.key, selector: Self.selector, operationIsCurrent: current)
    }

    // MARK: Null

    @Test func givenNullRepository_whenListingOrPatchIsRead_thenUnavailableIsExplicitAndKeyed() async throws {
        // given
        let repository = NullTaskChangesRepository()
        // when
        let listing = await repository.readListing(key: Self.key, operationIsCurrent: { true })
        let patch = await repository.readPatch(key: Self.key, selector: Self.selector, operationIsCurrent: { true })
        // then
        guard case .failure(let first) = listing, case .failure(let second) = patch else { Issue.record("Null must not fabricate a result"); return }
        #expect(first.detail == "Task changes unavailable" && second.detail == "Task changes unavailable")
        #expect(first.key == Self.key && second.key == Self.key)
    }

    // MARK: Listing

    @Test func givenSyntheticTwoPages_whenListed_thenRowsAreMergedKeyedAndPagedWithTheMaximumLimit() async throws {
        // given
        let harness = ChangesHarness([.page(["a", "b"], total: 3, cursor: "c1"), .page(["c"], total: 3)])
        // when
        let read = try await listing(harness).get()
        // then
        #expect(read.key == Self.key)
        #expect(read.value.repositories.first?.scope(.committedRange)?.rows.compactMap(\.path.utf8String) == ["a", "b", "c"])
        #expect(read.value.pagesRead == 2 && read.value.completeness.isComplete)
        #expect(harness.commands == [
            ["task-changes", "--limit=500", "--json", "--", "task"],
            ["task-changes", "--limit=500", "--cursor=c1", "--json", "--", "task"]
        ])
    }

    @Test func givenSyntheticTwoGenerations_whenReadSucceeds_thenEachResultEchoesItsOwnKey() async throws {
        // given
        let harness = ChangesHarness([.page(["a"], total: 1)])
        let older = TaskChangesKey(taskID: "task", generation: 1)
        let newer = TaskChangesKey(taskID: "task", generation: 2)
        // when
        let first = try await harness.repository.readListing(key: older, operationIsCurrent: { true }).get()
        let second = try await harness.repository.readListing(key: newer, operationIsCurrent: { true }).get()
        // then
        #expect(first.key == older && second.key == newer && first.key != second.key)
    }

    @Test(arguments: ["refusal", "malformed", "superseded"])
    func givenSyntheticTwoGenerations_whenReadFails_thenEachFailureEchoesItsOwnKey(mode: String) async {
        // given
        let current = LockedBox(true)
        let answer: ChangesHarness.Answer = mode == "malformed" ? .page(["a"], total: 5) : .refusal("unknown_task")
        let harness = ChangesHarness([answer]) { _ in if mode == "superseded" { current.mutate { $0 = false } } }
        let older = TaskChangesKey(taskID: "task", generation: 1)
        let newer = TaskChangesKey(taskID: "task", generation: 2)
        // when
        let first = await harness.repository.readListing(key: older, operationIsCurrent: { current.value })
        current.mutate { $0 = mode != "superseded" }
        let second = await harness.repository.readListing(key: newer, operationIsCurrent: { current.value })
        // then
        guard case .failure(let one) = first, case .failure(let two) = second else { Issue.record("Failures expected"); return }
        #expect(one.key == older && two.key == newer)
        #expect(one.isSuperseded == (mode == "superseded"))
    }

    @Test func givenSyntheticPendingCapture_whenListed_thenCaptureFactsAreReturnedWithoutAutomaticReRead() async throws {
        // given
        let harness = ChangesHarness([.pending("capture_settling")])
        // when
        let read = try await listing(harness).get()
        // then
        #expect(read.value.capture.state == .pending && read.value.capture.reason == "capture_settling")
        #expect(read.value.totalRows == 0 && !read.value.hasNoChanges && !read.value.completeness.isComplete)
        #expect(harness.commands.count == 1)
    }

    @Test func givenSyntheticCompleteCaptureWithNoRows_whenListed_thenNoChangesIsEstablished() async throws {
        // given
        let harness = ChangesHarness([.page([], total: 0)])
        // when
        let read = try await listing(harness).get()
        // then
        #expect(read.value.hasNoChanges)
    }

    // MARK: Cursor expiry

    @Test func givenSyntheticExpiryOnTheSecondPage_whenListed_thenReadRestartsFromTheFirstPage() async throws {
        // given
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .refusal("changes_cursor_expired"),
                               .page(["a"], total: 2, cursor: "c2"), .page(["b"], total: 2)])
        // when
        let read = try await listing(harness).get()
        // then
        #expect(read.value.repositories.first?.scope(.committedRange)?.rows.compactMap(\.path.utf8String) == ["a", "b"])
        #expect(harness.commands.count == 4)
        #expect(harness.commands[2] == ["task-changes", "--limit=500", "--json", "--", "task"], "restart carries no cursor")
        #expect(harness.commands[3].contains("--cursor=c2"))
    }

    @Test func givenSyntheticTwoExpiries_whenListed_thenTheSecondRestartStillSucceeds() async throws {
        // given
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .refusal("changes_cursor_expired"),
                               .page(["a"], total: 2, cursor: "c2"), .refusal("changes_cursor_expired"),
                               .page(["a"], total: 2, cursor: "c3"), .page(["b"], total: 2)])
        // when
        let read = try await listing(harness).get()
        // then
        #expect(read.value.totalRows == 2 && harness.commands.count == 6)
    }

    @Test func givenSyntheticThreeExpiries_whenListed_thenTheThirdIsSurfacedAfterAtMostTwoRestarts() async {
        // given
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .refusal("changes_cursor_expired"),
                               .page(["a"], total: 2, cursor: "c2"), .refusal("changes_cursor_expired"),
                               .page(["a"], total: 2, cursor: "c3"), .refusal("changes_cursor_expired")])
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Third expiry must surface"); return }
        #expect(error.isTaskChangesCursorExpired && TaskChangesLimits.maxRestarts == 2)
        #expect(harness.commands.count == 6)
    }

    @Test func givenSyntheticExpiryOnTheFirstPage_whenListed_thenItSurfacesWithoutRestart() async {
        // given
        let harness = ChangesHarness([.refusal("changes_cursor_expired")])
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Expiry must surface"); return }
        #expect(error.isTaskChangesCursorExpired && harness.commands.count == 1)
    }

    @Test(arguments: ["changes_cursor_invalid", "changes_entry_not_found", "changes_page_too_large", "task_pending_launch", "unknown_task",
                      "caller_undecidable", "agent_caller"])
    func givenSyntheticRefusal_whenListed_thenItPassesThroughUnchangedWithoutRestart(code: String) async {
        // given
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .refusal(code, data: ["launch_state": .string("waiting_for_resources")])])
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Refusal must surface"); return }
        #expect(error.refusalCode == code && error.refusalData == ["launch_state": .string("waiting_for_resources")])
        #expect(harness.commands.count == 2 && failure.key == Self.key)
    }

    // MARK: Inconsistent pages

    @Test(arguments: [
        ("repeated-cursor", "task-changes cursor repeated"), ("no-progress", "task-changes page made no progress"),
        ("other-task", "Malformed task-changes listing or mismatched task identity"),
        ("changed-document", "task-changes pages describe different documents"),
        ("row-overflow", "task-changes rows do not match the scope row count"), ("row-shortfall", "task-changes rows do not match the scope row count"),
        ("duplicate-path", "task-changes scope repeats a row path")
    ])
    func givenSyntheticInconsistentPages_whenListed_thenTheReadFailsWithAFixedMessage(mode: String, message: String) async {
        // given
        let second: ChangesHarness.Answer = switch mode {
        case "repeated-cursor": .page(["b"], total: 3, cursor: "c1")
        case "no-progress": .page([], total: 3, cursor: "c2")
        case "other-task": .page(["b"], total: 3, task: "other")
        case "changed-document": .page(["b"], total: 3, captureState: "incomplete")
        case "row-overflow": .page(["b", "c", "d"], total: 3)
        case "duplicate-path": .page(["a"], total: 3)
        default: .page(["b"], total: 3)
        }
        let harness = ChangesHarness([.page(["a"], total: 3, cursor: "c1"), second])
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result else { Issue.record("Inconsistent pages accepted"); return }
        #expect(failure.detail == message)
    }

    // MARK: Budget

    @Test(arguments: [119, 120, 121])
    func givenSyntheticInjectedClock_whenTheDeadlinePasses_thenTheNextRequestIsNotMadeAndTheReadTimesOut(elapsed: Int) async {
        // given
        let clock = ChangesFakeClock()
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .page(["b"], total: 2)], clock: clock) { served in
            if served == 1 { clock.advance(seconds: elapsed) }
        }
        // when
        let result = await listing(harness)
        // then
        if elapsed < TaskChangesLimits.maxReadSeconds {
            #expect((try? result.get().value.totalRows) == 2 && harness.commands.count == 2)
        } else {
            guard case .failure(let failure) = result, failure.clientBound == .deadline else { Issue.record("Deadline must stop the read"); return }
            #expect(harness.commands.count == 1 && failure.key == Self.key)
        }
    }

    @Test func givenSyntheticInjectedClock_whenTheDeadlinePassesAcrossARestart_thenThePatchReadTimesOut() async {
        // given
        let clock = ChangesFakeClock()
        let harness = ChangesHarness([.chunk("ab", offset: 0, total: 4, cursor: "t1"), .refusal("changes_cursor_expired"),
                               .chunk("ab", offset: 0, total: 4, cursor: "t2"), .chunk("cd", offset: 2, total: 4)], clock: clock) { served in
            if served == 2 { clock.advance(seconds: 120) }
        }
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result, failure.clientBound == .deadline else { Issue.record("Deadline must stop the read"); return }
        #expect(harness.commands.count == 2)
    }

    @Test func givenSyntheticSixtyFourRequests_whenListed_thenTheLastOneIsStillAllowed() async throws {
        // given
        let pages = (0 ..< 63).map { ChangesHarness.Answer.page(["p\($0)"], total: 64, cursor: "c\($0)") } + [.page(["last"], total: 64)]
        let harness = ChangesHarness(pages)
        // when
        let read = try await listing(harness).get()
        // then
        #expect(harness.commands.count == TaskChangesLimits.maxRequestsPerRead && read.value.totalRows == 64)
    }

    @Test func givenSyntheticRequestsSpanningARestart_whenTheSixtyFifthWouldRun_thenTheReadFailsOnTheBudget() async {
        // given: 40 pages, an expiry (41 requests), then a restart that would need 40 more
        let pass = (0 ..< 40).map { ChangesHarness.Answer.page(["p\($0)"], total: 100, cursor: "c\($0)") }
        let harness = ChangesHarness(pass + [.refusal("changes_cursor_expired")] + pass)
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result else { Issue.record("Request budget must stop the read"); return }
        #expect(failure.clientBound == .requestBudget && failure.error == nil)
        #expect(harness.commands.count == TaskChangesLimits.maxRequestsPerRead)
        #expect(TaskChangesLimits.maxRequestsPerRead == 64 && TaskChangesLimits.maxReadSeconds == 120)
    }

    @Test func givenSyntheticRequestsSpanningARestart_whenPatchIsRead_thenTheBudgetIsSharedAcrossRestarts() async {
        // given: chunks of one byte, so a pass of 30 chunks stays within the 32-chunk ceiling
        let pass = (0 ..< 30).map { ChangesHarness.Answer.chunk("x", offset: $0, total: 100, cursor: "t\($0)") }
        let harness = ChangesHarness(pass + [.refusal("changes_cursor_expired")] + pass + [.refusal("changes_cursor_expired")] + pass)
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result else { Issue.record("Request budget must stop the read"); return }
        #expect(failure.clientBound == .requestBudget && failure.error == nil)
        #expect(harness.commands.count == TaskChangesLimits.maxRequestsPerRead)
    }

    // MARK: Fence

    @Test func givenSyntheticObsoleteCallerBeforeRead_whenListed_thenNoProcessLaunchesAndTheFailureIsSuperseded() async {
        // given
        let harness = ChangesHarness([.page([], total: 0)])
        // when
        let result = await listing(harness) { false }
        // then
        guard case .failure(let failure) = result else { Issue.record("Obsolete request accepted"); return }
        #expect(failure.isSuperseded && failure.key == Self.key)
        #expect(harness.runner.allCalls.isEmpty && harness.recovery.state == .idle)
    }

    @Test func givenSyntheticCallerSupersededAfterTheFirstPage_whenListed_thenNoFurtherPageIsRequestedAndTheResultIsSuperseded() async {
        // given
        let current = LockedBox(true)
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .page(["b"], total: 2)]) { served in
            if served == 1 { current.mutate { $0 = false } }
        }
        // when
        let result = await listing(harness) { current.value }
        // then
        guard case .failure(let failure) = result else { Issue.record("Superseded read produced a result"); return }
        #expect(failure.isSuperseded && harness.commands.count == 1 && harness.recovery.state == .idle)
    }

    @Test func givenSyntheticCallerSupersededWhileTheLastPageIsInFlight_whenListed_thenTheCompleteResultIsStillSuperseded() async {
        // given
        let current = LockedBox(true)
        let harness = ChangesHarness([.page(["a"], total: 1)]) { _ in current.mutate { $0 = false } }
        // when
        let result = await listing(harness) { current.value }
        // then
        guard case .failure(let failure) = result else { Issue.record("Superseded result escaped"); return }
        #expect(failure.isSuperseded)
    }

    @Test(arguments: ["executable", "environment", "cancellation"])
    func givenSyntheticRuntimeChangeOrCancellation_whenListing_thenLaterPagesAreNotRequestedAndTheFailureIsSuperseded(mode: String) async {
        // given
        let idle = StubProcessRunner { _ in .success(stdout("")) }
        let selected = LockedBox(CtlClient(executable: "/fixture/ctl", environment: ["HOME": "/tmp/changes-test"], runner: idle))
        let task = LockedBox<Task<Result<TaskChangesRead<TaskChangesSnapshot>, TaskChangesReadFailure>, Never>?>(nil)
        let latch = StartLatch()
        let harness = ChangesHarness([.page(["a"], total: 2, cursor: "c1"), .page(["b"], total: 2)], environment: ["HOME": "/tmp/changes-test"],
                              selected: selected) { served in
            guard served == 1 else { return }
            switch mode {
            case "executable": selected.mutate { $0.executable = "/replacement/ctl" }
            case "environment": selected.mutate { $0.environment["CHANGES_GENERATION"] = "new" }
            default: task.value?.cancel()
            }
        }
        // when: the task is stored before it may start, so cancellation cannot fire early
        let operation = Task {
            await latch.wait()
            return await harness.repository.readListing(key: Self.key, operationIsCurrent: { true })
        }
        task.mutate { $0 = operation }
        await latch.open()
        let result = await operation.value
        // then
        guard case .failure(let failure) = result else { Issue.record("Obsolete result escaped"); return }
        #expect(failure.isSuperseded && failure.key == Self.key)
        #expect(harness.commands.count == 1)
        #expect(harness.recovery.state == .idle)
    }

    @Test func givenSyntheticStoreRefusalAfterTheFenceStoppedHolding_whenListed_thenItIsSupersededAndRecoveryStaysIdle() async {
        // given
        let current = LockedBox(true)
        let harness = ChangesHarness([.refusal("state_incompatible")]) { _ in current.mutate { $0 = false } }
        // when
        let result = await listing(harness) { current.value }
        // then
        guard case .failure(let failure) = result else { Issue.record("Obsolete refusal accepted"); return }
        #expect(failure.isSuperseded && failure.error == nil)
        #expect(harness.recovery.state == .idle)
    }

    @Test(arguments: ["changes_entry_not_found", "unknown_task", "changes_cursor_expired"])
    func givenSyntheticToolErrorAfterTheFenceStoppedHolding_whenListedOrPatched_thenItIsClassifiedSuperseded(code: String) async {
        // given
        let current = LockedBox(true)
        let first = ChangesHarness([.refusal(code)]) { _ in current.mutate { $0 = false } }
        let second = ChangesHarness([.refusal(code)]) { _ in current.mutate { $0 = false } }
        // when
        let listed = await listing(first) { current.value }
        current.mutate { $0 = true }
        let patched = await patch(second) { current.value }
        // then
        guard case .failure(let one) = listed, case .failure(let two) = patched else { Issue.record("Failures expected"); return }
        #expect(one.isSuperseded && two.isSuperseded)
        #expect(first.recovery.state == .idle && second.recovery.state == .idle)
    }

    @Test func givenSyntheticToolEnvironmentFailureAfterTheFenceStoppedHolding_whenListed_thenItIsSupersededAndNotReported() async {
        // given
        let current = LockedBox(true)
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willProduce {
            current.mutate { $0 = false }
            return .failure(.notFound(tool: "harflow-ctl", searched: ["/none"]))
        }
        let recovery = StateRecoveryRepositoryImpl(toolEnvironment: tools)
        let repository = TaskChangesRepositoryImpl(toolEnvironment: tools, recovery: recovery, now: { .now })
        // when
        let result = await repository.readListing(key: Self.key, operationIsCurrent: { current.value })
        // then
        guard case .failure(let failure) = result else { Issue.record("Obsolete failure accepted"); return }
        #expect(failure.isSuperseded && recovery.state == .idle)
    }

    @Test func givenSyntheticCurrentStoreRefusal_whenListed_thenRecoveryReceivesIt() async {
        // given
        let harness = ChangesHarness([.refusal("state_incompatible")])
        // when
        let result = await listing(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Store refusal accepted"); return }
        #expect(error.refusalCode == "state_incompatible")
        #expect(harness.recovery.state == .incompatible(error))
    }

    @Test func givenSyntheticMissingCapability_whenListedTwice_thenNeitherReadFallsBackOrCachesPermission() async {
        // given
        let capable = LockedBox(true)
        let harness = ChangesHarness([.page([], total: 0)], capability: capable)
        // when
        let first = await listing(harness)
        capable.mutate { $0 = false }
        let second = await listing(harness)
        // then
        #expect((try? first.get()) != nil)
        guard case .failure(let failure) = second, case .unsupportedCommand? = failure.error else {
            Issue.record("Missing capability must remain an error")
            return
        }
        #expect(harness.runner.allCalls.filter { $0.arguments.first == "version-info" }.count == 2)
        #expect(harness.commands.count == 1)
    }

    @Test func givenSyntheticToolEnvironmentFailure_whenListedOrPatched_thenTheErrorIsReturnedKeyedWithoutLaunchingAnything() async {
        // given
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.failure(.notFound(tool: "harflow-ctl", searched: ["/none"])))
        let repository = TaskChangesRepositoryImpl(toolEnvironment: tools, recovery: StateRecoveryRepositoryImpl(toolEnvironment: tools), now: { .now })
        // when
        let listing = await repository.readListing(key: Self.key, operationIsCurrent: { true })
        let patch = await repository.readPatch(key: Self.key, selector: Self.selector, operationIsCurrent: { true })
        // then
        guard case .failure(let one) = listing, case .failure(let two) = patch, case .notFound? = one.error, case .notFound? = two.error else {
            Issue.record("Tool failure must surface")
            return
        }
        #expect(one.key == Self.key && two.key == Self.key)
    }

    // MARK: Patch

    @Test func givenSyntheticTwoChunks_whenPatchRead_thenBytesAreJoinedKeyedAndTheSecondRequestIsTheCursorAlone() async throws {
        // given
        let harness = ChangesHarness([.chunk("diff\n", offset: 0, total: 9, cursor: "t1"), .chunk("+x\n+", offset: 5, total: 9)])
        // when
        let read = try await patch(harness).get()
        // then
        #expect(read.key == Self.key && read.value.utf8String == "diff\n+x\n+" && read.value.selector == Self.selector)
        #expect(harness.commands == [
            ["task-changes", "--repository-root=/workspace/repo", "--scope=working_tree",
             "--path-b64=\(Data("a.txt".utf8).base64EncodedString())", "--json", "--", "task"],
            ["task-changes", "--cursor=t1", "--json", "--", "task"]
        ])
    }

    @Test func givenSyntheticNonUtf8Chunks_whenPatchRead_thenBytesAreExact() async throws {
        // given
        let first: [UInt8] = [0x2B, 0xC3]
        let second: [UInt8] = [0xA9, 0xFF]
        let harness = ChangesHarness([.chunkBytes(first, offset: 0, total: 4, cursor: "t1"), .chunkBytes(second, offset: 2, total: 4)])
        // when
        let read = try await patch(harness).get()
        // then
        #expect(read.value.bytes == Data(first + second) && read.value.encoding == .base64 && read.value.utf8String == nil)
    }

    @Test func givenSyntheticExpiryOnTheSecondChunk_whenPatchRead_thenReadRestartsFromTheSelector() async throws {
        // given
        let harness = ChangesHarness([.chunk("ab", offset: 0, total: 4, cursor: "t1"), .refusal("changes_cursor_expired"),
                               .chunk("ab", offset: 0, total: 4, cursor: "t2"), .chunk("cd", offset: 2, total: 4)])
        // when
        let read = try await patch(harness).get()
        // then
        #expect(read.value.utf8String == "abcd" && harness.commands.count == 4)
        #expect(harness.commands[2].contains("--repository-root=/workspace/repo"), "restart uses the selector, not the cursor")
        #expect(!harness.commands[2].contains { $0.hasPrefix("--cursor=") })
    }

    @Test func givenSyntheticThreeChunkExpiries_whenPatchRead_thenTheThirdIsSurfacedAfterAtMostTwoRestarts() async {
        // given
        let harness = ChangesHarness([.chunk("ab", offset: 0, total: 4, cursor: "t1"), .refusal("changes_cursor_expired"),
                               .chunk("ab", offset: 0, total: 4, cursor: "t2"), .refusal("changes_cursor_expired"),
                               .chunk("ab", offset: 0, total: 4, cursor: "t3"), .refusal("changes_cursor_expired")])
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Third expiry must surface"); return }
        #expect(error.isTaskChangesCursorExpired && harness.commands.count == 6)
    }

    @Test func givenSyntheticExpiryOnTheFirstChunk_whenPatchRead_thenItSurfacesWithoutRestart() async {
        // given
        let harness = ChangesHarness([.refusal("changes_cursor_expired")])
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Expiry must surface"); return }
        #expect(error.isTaskChangesCursorExpired && harness.commands.count == 1)
    }

    @Test(arguments: ["changes_entry_not_found", "changes_cursor_invalid", "changes_page_too_large", "caller_undecidable"])
    func givenSyntheticRefusal_whenPatchRead_thenItPassesThroughUnchanged(code: String) async {
        // given
        let harness = ChangesHarness([.refusal(code)])
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result, let error = failure.error else { Issue.record("Refusal must surface"); return }
        #expect(error.refusalCode == code && harness.commands.count == 1 && failure.key == Self.key)
    }

    @Test(arguments: [
        ("gap", "task-changes text chunks are not contiguous"), ("encoding", "task-changes text encoding changed between chunks"),
        ("other-row", "task-changes text does not match the requested row"), ("repeated-cursor", "task-changes cursor repeated"),
        ("changed-total", "task-changes pages describe different documents")
    ])
    func givenSyntheticInconsistentChunks_whenPatchRead_thenTheReadFailsWithAFixedMessageWithoutDiffText(mode: String, message: String) async {
        // given
        let size = Self.secret.utf8.count
        let total = 2 + size + 1
        let second: ChangesHarness.Answer = switch mode {
        case "gap": .chunk(Self.secret, offset: 3, total: 3 + size)
        case "encoding": .chunkBytes(Array(Self.secret.utf8), offset: 2, total: 2 + size)
        case "other-row": .chunk(Self.secret, offset: 2, total: total, cursor: "t2", path: "b.txt")
        case "repeated-cursor": .chunk(Self.secret, offset: 2, total: total, cursor: "t1")
        default: .chunk(Self.secret, offset: 2, total: total + 5, cursor: "t2")
        }
        let first: ChangesHarness.Answer = mode == "gap" ? .chunk("ab", offset: 0, total: 3 + size, cursor: "t1")
            : mode == "encoding" ? .chunk("ab", offset: 0, total: 2 + size, cursor: "t1") : .chunk("ab", offset: 0, total: total, cursor: "t1")
        let harness = ChangesHarness([first, second])
        // when
        let result = await patch(harness)
        // then
        guard case .failure(let failure) = result else { Issue.record("Inconsistent chunks accepted"); return }
        #expect(failure.detail == message)
        #expect(!String(describing: result).contains(Self.secret))
    }

    @Test func givenSyntheticCallerSupersededAfterTheFirstChunk_whenPatchRead_thenNoFurtherChunkIsRequested() async {
        // given
        let current = LockedBox(true)
        let harness = ChangesHarness([.chunk("ab", offset: 0, total: 4, cursor: "t1"), .chunk("cd", offset: 2, total: 4)]) { served in
            if served == 1 { current.mutate { $0 = false } }
        }
        // when
        let result = await patch(harness) { current.value }
        // then
        guard case .failure(let failure) = result else { Issue.record("Superseded read produced a result"); return }
        #expect(failure.isSuperseded && harness.commands.count == 1)
    }

    @Test func givenSyntheticObsoleteCallerBeforePatchRead_whenRequested_thenNoProcessLaunches() async {
        // given
        let harness = ChangesHarness([.chunk("ab", offset: 0, total: 2)])
        // when
        let result = await patch(harness) { false }
        // then
        guard case .failure(let failure) = result else { Issue.record("Obsolete request accepted"); return }
        #expect(failure.isSuperseded && harness.runner.allCalls.isEmpty)
    }

    // MARK: Privacy

    @Test func givenSyntheticPatchWithDiffText_whenTheReadResultIsDescribed_thenNoDiffTextAppears() async throws {
        // given
        let harness = ChangesHarness([.chunk("+\(Self.secret)\n", offset: 0, total: Self.secret.utf8.count + 2)])
        // when
        let result = await patch(harness)
        let read = try result.get()
        // then
        for rendering in [String(describing: read), String(reflecting: read), "\(read)", String(describing: result), String(describing: read.value)] {
            #expect(!rendering.contains(Self.secret))
        }
        #expect(read.value.utf8String?.contains(Self.secret) == true, "the caller still receives the text")
    }
}
