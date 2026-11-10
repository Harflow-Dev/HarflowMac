import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - TaskContinuationReachabilityTests

struct TaskContinuationReachabilityTests {
    @Test func givenUnknownSource_whenTargetedPathProvesUnlistedGrandchild_thenExplicitLaunchIsAdmitted() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)), pages: ContinuationPages([
            .success(continuationPage(["next"])), .success(continuationPage(["grandchild"], source: "next"))
        ]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        #expect(await harness.repository.start(harness.request("grandchild")) == .refused(.missingIdentity))
        // when
        await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
        // then
        let checked = try #require(harness.repository.state(for: harness.request()))
        #expect(checked.check == .reachable(sourceTaskID: "grandchild"))
        #expect(checked.recordedReachableSourceTaskIDs == ["grandchild"])
        #expect(checked.recordedSuccessorTaskIDs.isEmpty)
        #expect(checked.permitsRecordedSource("grandchild"))
        #expect(!checked.permitsRecordedSource("source"))
        #expect(checked.outcome == original.outcome)
        #expect(await harness.runner.commands.count == 1)
        #expect(await harness.repository.start(harness.request()) == .existing(original.id))
        guard case .started = await harness.repository.start(harness.request("grandchild")) else {
            Issue.record("A positive path must admit explicit Continue without launching its intermediate source")
            return
        }
        #expect(await harness.runner.commands.count == 2)
    }

    @Test func givenRelatedOnlyOrIncompleteParent_whenTargetedRead_thenNoPathProof() async throws {
        // given
        let sequences = [
            [continuationPage(related: ["grandchild"])],
            [continuationPage(["next"], cursor: "more"),
             continuationPage(overrides: ["history_incomplete": .bool(true)]),
             continuationPage(["grandchild"], source: "next")],
            [continuationPage(["next"]), continuationPage(["grandchild"], source: "next",
                                                          overrides: ["authority_incomplete": .bool(true)])]
        ]
        for sequence in sequences {
            let harness = ContinuationHarness(pages: ContinuationPages(sequence.map { .success($0) }))
            _ = await harness.repository.start(harness.request())
            let original = try #require(harness.repository.state(for: harness.request()))
            // when
            await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
            // then
            #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
            #expect(harness.repository.state(for: harness.request())?.recordedReachableSourceTaskIDs.isEmpty == true)
            #expect(await harness.runner.commands.count == 1)
        }
    }

    @Test func givenCyclesAndSharedPageBudget_whenTargetedRead_thenNoRepeatedExpansionOrFifthPage() async throws {
        // given
        let sequences = [
            [continuationPage(["next"]), continuationPage(["source"], source: "next")],
            [continuationPage(["next"], cursor: "more"), continuationPage(),
             continuationPage(["other"], source: "next"), continuationPage(["deep"], source: "other"),
             continuationPage(["grandchild"], source: "deep")]
        ]
        for sequence in sequences {
            let harness = ContinuationHarness(pages: ContinuationPages(sequence.map { .success($0) }))
            _ = await harness.repository.start(harness.request())
            let original = try #require(harness.repository.state(for: harness.request()))
            // when
            await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
            // then
            #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
            #expect(await harness.pages.cursors.count == min(sequence.count, 4))
        }
    }

    @Test func givenRetainedPath_whenLaterReadFails_thenProofAndUnknownOutcomeSurvive() async throws {
        // given
        let failure = ToolError.notFound(tool: "fixture", searched: [])
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)), pages: ContinuationPages([
            .success(continuationPage(["next"])), .success(continuationPage(["grandchild"], source: "next")), .failure(failure)
        ]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
        // when
        await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
        // then
        let checked = try #require(harness.repository.state(for: harness.request()))
        #expect(checked.check == .failed(.tool(failure)))
        #expect(checked.permitsRecordedSource("grandchild"))
        #expect(checked.outcome == original.outcome)
    }

    @Test func givenTargetedReadParked_whenDirectCheckAndCancellation_thenSharedSingleFlightRestoresState() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(pages: ContinuationPages([.success(continuationPage(["next"]))], latch: latch))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: original.id, targetSourceTaskID: "next") }
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

    @Test(arguments: [true, false])
    func givenCombinedProofCapacity_whenOtherCheckAddsNewIDs_thenPriorProofIsRetained(directFirst: Bool) async throws {
        // given
        let direct = (0 ..< 4).map { page in
            continuationPage((0 ..< 100).map { "direct-\(page)-\($0)" }, cursor: page < 3 ? "page-\(page + 1)" : nil)
        }
        let path = continuationPage(["unlisted"])
        let pages = directFirst ? direct + [path] : [path] + direct
        let harness = ContinuationHarness(pages: ContinuationPages(pages.map { .success($0) }))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        if directFirst {
            await harness.repository.check(attemptID: original.id)
            await harness.repository.check(attemptID: original.id, targetSourceTaskID: "unlisted")
        } else {
            await harness.repository.check(attemptID: original.id, targetSourceTaskID: "unlisted")
            await harness.repository.check(attemptID: original.id)
        }
        // then
        let checked = try #require(harness.repository.state(for: harness.request()))
        #expect(checked.check == .inconclusive)
        #expect(checked.recordedSuccessorTaskIDs.count == (directFirst ? 400 : 0))
        #expect(checked.recordedReachableSourceTaskIDs == (directFirst ? [] : ["unlisted"]))
        #expect(checked.outcome == original.outcome)
    }

    @Test func givenTargetOnIncompletePage_whenTargetedRead_thenCompletionIsRequired() async throws {
        // given
        let failure = ToolError.notFound(tool: "fixture", searched: [])
        let harness = ContinuationHarness(pages: ContinuationPages([
            .success(continuationPage(["grandchild"], cursor: "pending")), .failure(failure)
        ]))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        // when
        await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .failed(.tool(failure)))
        #expect(harness.repository.state(for: harness.request())?.permitsRecordedSource("grandchild") == false)
    }

    @Test func givenRetainedPath_whenLaterTargetedReadCancelled_thenProofAndCheckSurvive() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(pages: ContinuationPages([
            .success(continuationPage(["grandchild"])), .success(continuationPage())
        ], latch: latch, latchAtRead: 2))
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild")
        let proven = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: original.id, targetSourceTaskID: "other") }
        await latch.waitForArrival()
        // when
        read.cancel()
        await latch.release()
        await read.value
        // then
        #expect(harness.repository.state(for: harness.request()) == proven)
    }

    @Test func givenDeadlineExpiresAcrossTargetedAwait_whenPageReturns_thenNoProof() async throws {
        // given
        let latch = ContinuationLatch()
        let instant = LockedBox(ContinuousClock.now)
        let harness = ContinuationHarness(pages: ContinuationPages([
            .success(continuationPage(["grandchild"]))
        ], latch: latch), now: { instant.value })
        _ = await harness.repository.start(harness.request())
        let original = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: original.id, targetSourceTaskID: "grandchild") }
        await latch.waitForArrival()
        // when
        instant.mutate { $0 = $0.advanced(by: .seconds(121)) }
        await latch.release()
        await read.value
        // then
        #expect(harness.repository.state(for: harness.request())?.check == .inconclusive)
        #expect(harness.repository.state(for: harness.request())?.permitsRecordedSource("grandchild") == false)
    }

}
