import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - TaskContinuationCheckTests

struct TaskContinuationCheckTests {
    @Test func givenAcceptedIDOnly_whenNewSourceRequested_thenRecordedBridgeIsRequired() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: "next")),
                                          pages: ContinuationPages([.success(continuationPage(["next", "other"]))]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        let before = await harness.repository.start(harness.request("next"))
        await harness.repository.check(attemptID: original.id)
        // then
        #expect(before == .existing(original.id))
        #expect(harness.repository.state(for: harness.request())?.check == .recorded(successorTaskIDs: ["next", "other"]))
        #expect(harness.repository.state(for: harness.request())?.outcome == original.outcome)
        #expect(await harness.runner.commands.count == 1)
        guard case .started = await harness.repository.start(harness.request("other")) else {
            Issue.record("Caller may explicitly choose a recorded successor")
            return
        }
        #expect(await harness.runner.commands.count == 2)
        #expect(await harness.repository.start(harness.request(conversation: "alias")) == .existing(original.id))
    }

    @Test func givenUnknownWithEmptyOrRelatedOnlyRead_whenChecked_thenSourceRemainsLocked() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)),
                                          pages: ContinuationPages([.success(continuationPage(related: ["next"]))]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        await harness.repository.check(attemptID: original.id)
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .recorded(successorTaskIDs: []))
        #expect(harness.repository.state(for: harness.request())?.outcome == original.outcome)
        #expect(await harness.repository.start(harness.request("next")) == .existing(original.id))
        #expect(await harness.repository.start(harness.request()) == .existing(original.id))
        #expect(await harness.runner.commands.count == 1)
    }

    @Test(arguments: ["bootstrap_pending", "history_incomplete", "authority_incomplete", "catalog_state"])
    func givenUnhealthyRead_whenChecked_thenNoPositiveBridgeIsRecorded(field: String) async throws {
        // given
        let value: JSONValue = field == "catalog_state"
            ? .object(["status": .string("blocked"), "source": .string("fixture"), "pending_records": .number(0), "blocked_records": .number(1)])
            : .bool(true)
        let page = continuationPage(["next"], overrides: [field: value])
        let harness = ContinuationHarness(pages: ContinuationPages([.success(page)]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        await harness.repository.check(attemptID: original.id)
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
        #expect(await harness.repository.start(harness.request("next")) == .existing(original.id))
    }

    @Test func givenUnknownReadiness_whenChecked_thenNoBridgeIsRecorded() async throws {
        // given
        var raw: [String: JSONValue] = [
            "predecessor_task_id": .string("source"), "successor_scope": .string("recorded_tasks"),
            "items": .array([]), "has_more": .bool(false), "next_cursor": .null, "bootstrap_pending": .bool(false)
        ]
        raw["counts_complete"] = .bool(true)
        let page = try #require(TaskSuccessorPage(raw: raw, predecessorTaskID: "source"))
        let harness = ContinuationHarness(pages: ContinuationPages([.success(page)]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        await harness.repository.check(attemptID: original.id)
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
    }

    @Test func givenFailureAfterPositiveCheck_whenCheckedAgain_thenKnownEdgesAndImmutableOutcomeSurvive() async throws {
        // given
        let failure = ToolError.notFound(tool: "fixture", searched: [])
        let harness = ContinuationHarness(pages: ContinuationPages([.success(continuationPage(["next"])), .failure(failure)]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        await harness.repository.check(attemptID: original.id)
        // when
        await harness.repository.check(attemptID: original.id)
        // then
        let current = try #require(harness.repository.state(for: harness.request()))
        #expect(current.check == .failed(.tool(failure)))
        #expect(current.recordedSuccessorTaskIDs == ["next"])
        #expect(current.outcome == original.outcome)
        guard case .started = await harness.repository.start(harness.request("next")) else {
            Issue.record("Known recorded fact must survive failed check")
            return
        }
    }

    @Test func givenParkedCheck_whenCheckedTwiceThenCancelled_thenSingleFlightAndOldEvidenceRemain() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(pages: ContinuationPages([.success(continuationPage(["next"]))], latch: latch))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: original.id) }
        await latch.waitForArrival()
        // when
        await harness.repository.check(attemptID: original.id)
        #expect(await harness.pages.cursors.count == 1)
        read.cancel()
        await latch.release()
        await read.value
        // then
        #expect(harness.repository.state(for: harness.request()) == original)
        #expect(await harness.runner.commands.count == 1)
    }

    @Test func givenRepeatedCursorOrDuplicateRows_whenChecked_thenReadStopsWithoutBridge() async throws {
        // given
        let sequences = [
            [continuationPage(["next"], cursor: "same"), continuationPage(["other"], cursor: "same")],
            [continuationPage(["next"], cursor: "second"), continuationPage(["next"])]
        ]
        for sequence in sequences {
            let harness = ContinuationHarness(pages: ContinuationPages(sequence.map { .success($0) }))
            _ = await harness.repository.start(harness.request())
            let original = try #require(harness.repository.state(for: harness.request()))
            // when
            await harness.repository.check(attemptID: original.id)
            // then
            #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
            #expect(await harness.pages.cursors.count == 2)
        }
    }

    @Test func givenPageOrRowBound_whenChecked_thenNoFifthPageOrPartialBridge() async throws {
        // given
        let pageBound = (0 ..< 5).map { continuationPage(["id-\($0)"], cursor: "cursor-\($0)") }
        let rows = (0 ..< 100).map { "id-\($0)" }
        let rowBound = [continuationPage(rows, cursor: "next", related: rows),
                        continuationPage(rows.map { "b-\($0)" }, cursor: "third", related: rows),
                        continuationPage(["next"])]
        for sequence in [pageBound, rowBound] {
            let harness = ContinuationHarness(pages: ContinuationPages(sequence.map { .success($0) }))
            _ = await harness.repository.start(harness.request())
            let original = try #require(harness.repository.state(for: harness.request()))
            // when
            await harness.repository.check(attemptID: original.id)
            // then
            #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
            #expect(await harness.pages.cursors.count <= 4)
        }
    }

    @Test func givenDeadlineExpiresAcrossAwait_whenPageReturns_thenPositivePageCannotUnlock() async throws {
        // given
        let latch = ContinuationLatch()
        let instant = LockedBox(ContinuousClock.now)
        let harness = ContinuationHarness(pages: ContinuationPages([.success(continuationPage(["next"]))], latch: latch), now: { instant.value })
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: original.id) }
        await latch.waitForArrival()
        // when
        instant.mutate { $0 = $0.advanced(by: .seconds(121)) }
        await latch.release()
        await read.value
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
        #expect(await harness.repository.start(harness.request("next")) == .existing(original.id))
    }
}
