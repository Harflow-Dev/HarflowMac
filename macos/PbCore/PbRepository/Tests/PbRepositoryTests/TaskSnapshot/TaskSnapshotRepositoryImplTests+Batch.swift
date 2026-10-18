import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

// MARK: - TaskSnapshotRepositoryImpl batched refresh (B3)

/// A running snapshot entry with a start time (so only its duration can drift).
private func runningEntry(_ id: String, backend: String = "claude", extra: String = "") -> String {
    #"{"task_id":"\#(id)","status":"running","backend":"\#(backend)","started_at":"2026-10-17T10:00:00+00:00"\#(extra)}"#
}

/// A `status-batch` document around already-encoded entries and an encoded `errors` object.
private func batchDocument(_ entries: [String], errors: String = "{}") -> String {
    #"{"v":11,"tasks":[\#(entries.joined(separator: ","))],"errors":\#(errors)}"#
}

extension TaskSnapshotRepositoryImplTests {

    private func makeToolEnvironment(runner: StubProcessRunner) -> MockToolEnvironmentRepository {
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        return toolEnvironment
    }

    @Test func givenLeasedIds_whenRefreshedAsABatch_thenOneProcessCoversThemAll() async {
        // given
        let runner = StubProcessRunner(output: stdout(
            batchDocument([runningEntry("a"), runningEntry("b", backend: "codex")])
        ))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: makeToolEnvironment(runner: runner))

        // when
        await sut.refresh(ids: ["a", "b"])

        // then — one `status-batch` invocation, both snapshots stored.
        #expect(runner.calls.count == 1)
        #expect(runner.calls[0].arguments.first == "status-batch")
        #expect(sut.snapshot("a")?.taskID == "a")
        #expect(sut.snapshot("b")?.taskID == "b")
    }

    @Test func givenDuplicateIds_whenRefreshedAsABatch_thenTheyAreDedupedKeepingOrder() async {
        // given
        let runner = StubProcessRunner(output: stdout(batchDocument([runningEntry("b"), runningEntry("a")])))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: makeToolEnvironment(runner: runner))

        // when — a duplicate must not trap the generation dictionary.
        await sut.refresh(ids: ["b", "a", "b", "a"])

        // then
        let option = runner.calls[0].arguments.first { $0.hasPrefix("--task-ids=") }
        #expect(option == "--task-ids=b,a")
        #expect(sut.snapshot("a") != nil)
    }

    @Test func givenMixedBatchOutcomes_whenApplied_thenUnknownEvictsAndOtherErrorsRetain() async {
        // given — "c" carries a seeded snapshot that must survive its own batch answer, and "b"
        // has none, so its refusal has nothing to retain (exactly the single-refresh policy).
        let toolEnvironment = MockToolEnvironmentRepository()
        let ctlBox = LockedBox<Result<CtlClient, ToolError>>(.success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(
                batchDocument([runningEntry("c")])
            ))
        )))
        given(toolEnvironment).ctl().willProduce { ctlBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh(ids: ["c"])
        #expect(sut.snapshot("c") != nil)

        // when — a mixed batch: "a" answers, "b" is refused, "c" is unknown.
        ctlBox.mutate { $0 = .success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout(
            batchDocument([#"{"task_id":"a","status":"completed","backend":"claude"}"#],
                errors: #"{"b":{"code":"agent_caller","message":"refused"},"c":{"code":"unknown_task","message":"gone"}}"#)
        )))) }
        await sut.refresh(ids: ["a", "b", "c"])

        // then — per-id outcomes follow the single-refresh policy exactly: a returned snapshot
        // stores, `unknown_task` evicts, any other error retains.
        #expect(sut.snapshot("a")?.taskID == "a")
        #expect(sut.snapshot("b") == nil)
        #expect(sut.snapshot("c") == nil)
    }

    @Test func givenAnUnansweredId_whenABatchAnswers_thenTheStaleSnapshotIsRetained() async {
        // given — a pre-seeded snapshot for an id the batch neither answers nor errors.
        let seedRunner = StubProcessRunner(output: stdout(batchDocument([runningEntry("x")])))
        let toolEnvironment = MockToolEnvironmentRepository()
        let ctlBox = LockedBox<Result<CtlClient, ToolError>>(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: seedRunner)))
        given(toolEnvironment).ctl().willProduce { ctlBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh(ids: ["x"])
        #expect(sut.snapshot("x") != nil)

        // when — the batch answers nothing for "x" (and reports no error for it either).
        ctlBox.mutate { $0 = .success(CtlClient(executable: "/bin/echo", environment: [:], runner: StubProcessRunner(output: stdout(
            batchDocument([])
        )))) }
        await sut.refresh(ids: ["x"])

        // then — the stale snapshot is retained, exactly as a per-id failure would.
        #expect(sut.snapshot("x")?.taskID == "x")
    }

    @Test func givenAnOlderCtlWithoutStatusBatch_whenABatchIsRequested_thenItFallsBackPerIdForTheSession() async {
        // given — the first batch attempt hits an argparse exit 2.
        let toolEnvironment = MockToolEnvironmentRepository()
        let runner = StubProcessRunner { call in
            if call.arguments.first == "status-batch" {
                return .success(ProcessOutput(exitCode: 2, stdout: Data(), stderr: "invalid choice: 'status-batch'", timedOut: false))
            }
            return .success(stdout(#"{"v":11,"task":{"task_id":"\#(call.arguments.last ?? "")","status":"completed","backend":"claude"}}"#))
        }
        given(toolEnvironment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)

        // when
        await sut.refresh(ids: ["a", "b"])

        // then — the failed batch plus two per-id statuses.
        #expect(runner.calls.count == 3)
        #expect(runner.calls.map(\.arguments.first) == ["status-batch", "status", "status"])
        #expect(sut.snapshot("a")?.taskID == "a")
        #expect(sut.snapshot("b")?.taskID == "b")

        // and — a later batch goes straight to per-id refreshes: the session remembers.
        await sut.refresh(ids: ["a", "b"])
        #expect(runner.calls.count == 5)
        #expect(runner.calls.dropFirst(3).allSatisfy { $0.arguments.first == "status" })
    }

    @Test func givenAWholeBatchFailure_whenRefreshed_thenEverySnapshotStaysAsItIs() async {
        // given — seed two snapshots through a working client.
        let toolEnvironment = MockToolEnvironmentRepository()
        let ctlBox = LockedBox<Result<CtlClient, ToolError>>(.success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: stdout(
                batchDocument([runningEntry("a"), runningEntry("b", backend: "codex")])
            ))
        )))
        given(toolEnvironment).ctl().willProduce { ctlBox.value }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: toolEnvironment)
        await sut.refresh(ids: ["a", "b"])
        #expect(sut.snapshot("a") != nil)
        #expect(sut.snapshot("b") != nil)

        // when — the batch times out as a whole.
        ctlBox.mutate { $0 = .success(CtlClient(
            executable: "/bin/echo", environment: [:],
            runner: StubProcessRunner(output: ProcessOutput(exitCode: 0, stdout: Data(), stderr: "", timedOut: true))
        )) }
        await sut.refresh(ids: ["a", "b"])

        // then
        #expect(sut.snapshot("a")?.taskID == "a")
        #expect(sut.snapshot("b")?.taskID == "b")
    }

    @Test func givenABatchInFlight_whenAFresherSingleRefreshAnswers_thenTheStaleBatchEntryIsDiscarded() async {
        // given — the batch call parks on a gate; the single `status` call answers immediately.
        let gate = AsyncGate()
        let answered = LockedBox(false)
        let runner = StubProcessRunner { call in
            if call.arguments.first == "status-batch" {
                gate.waitSync()
                // The stale batch answer: "a" is running.
                return .success(stdout(batchDocument([runningEntry("a")])))
            }
            // The fresher single refresh: "a" has completed.
            answered.mutate { $0 = true }
            return .success(stdout(#"{"v":11,"task":{"task_id":"a","status":"completed","backend":"claude"}}"#))
        }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: makeToolEnvironment(runner: runner))

        // when — the batch starts, a single refresh for the same id starts after it and answers
        // first, then the batch is released.
        let batch = Task { await sut.refresh(ids: ["a"]) }
        await waitUntil { !runner.calls.isEmpty }
        await sut.refresh("a")
        #expect(answered.value)
        gate.open()
        await batch.value

        // then — the newer single-refresh result wins; the stale batch entry cannot overwrite it.
        #expect(sut.snapshot("a")?.status == .completed)
    }

    @Test func givenEquivalentSnapshots_whenABatchAnswers_thenNoPublicationHappens() async {
        // given — a running task with a start time: only its duration drifts between the two calls.
        let runner = StubProcessRunner { _ in
            .success(stdout(batchDocument([runningEntry("a", extra: ",\"duration_seconds\":12")])))
        }
        let sut = TaskSnapshotRepositoryImpl(toolEnvironment: makeToolEnvironment(runner: runner))
        var published = 0
        let token = sut.snapshotsPublisher().sink { _ in published += 1 }

        // when
        await sut.refresh(ids: ["a"])
        // The subject emits its initial empty dictionary, then the first stored batch.
        let afterFirst = published
        #expect(afterFirst == 2)
        await sut.refresh(ids: ["a"])

        // then — the equivalent second answer publishes nothing.
        #expect(published == afterFirst)
        token.cancel()
    }
}
