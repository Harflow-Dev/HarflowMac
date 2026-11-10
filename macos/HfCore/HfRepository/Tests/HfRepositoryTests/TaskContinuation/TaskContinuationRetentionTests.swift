import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - TaskContinuationRetentionTests

struct TaskContinuationRetentionTests {
    @Test func givenMissingCapabilityPair_whenExplicitlyRetriedAfterQualification_thenFreshUUIDAndNoFirstDispatch() async throws {
        // given
        let runner = ContinuationRunner()
        await runner.setCapabilities(["ctl.v1", "task-continue.v1"])
        let harness = ContinuationHarness(runner: runner)
        _ = await harness.repository.start(harness.request())
        let first = try #require(harness.repository.state(for: harness.request()))
        // when
        await runner.setCapabilities(["ctl.v1", "task-continue.v1", "task-successors.v1"])
        _ = await harness.repository.start(harness.request())
        let second = try #require(harness.repository.state(for: harness.request()))
        // then
        guard case .notDispatched? = first.outcome else { Issue.record("Capability gate must precede dispatch"); return }
        #expect(second.id != first.id)
        #expect(second.outcome == .launched(taskID: "accepted"))
        #expect(await runner.commands.count == 1)
    }

    @Test func givenFullSessionCapacity_whenExplicitRetryRequested_thenNoRecordIsEvicted() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(error: "fixture", exit: 1)))
        var ids = Set<UUID>()
        for _ in 0 ..< 256 {
            _ = await harness.repository.start(harness.request())
            ids.insert(try #require(harness.repository.state(for: harness.request())).id)
        }
        let last = try #require(harness.repository.state(for: harness.request()))
        // when
        let result = await harness.repository.start(harness.request())
        // then
        #expect(ids.count == 256)
        #expect(result == .refused(.capacity))
        #expect(harness.repository.state(for: harness.request()) == last)
        #expect(await harness.runner.commands.count == 256)
    }

    @Test func givenOldCheckAndExplicitRetry_whenOldPageReturns_thenNewAttemptIsNotOverwritten() async throws {
        // given
        let latch = ContinuationLatch()
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(error: "fixture", exit: 1)),
                                          pages: ContinuationPages([.success(continuationPage(["next"]))], latch: latch))
        _ = await harness.repository.start(harness.request())
        let first = try #require(harness.repository.state(for: harness.request()))
        let read = Task { await harness.repository.check(attemptID: first.id) }
        await latch.waitForArrival()
        // when
        await harness.runner.setOutput(continuationOutput())
        _ = await harness.repository.start(harness.request())
        let second = try #require(harness.repository.state(for: harness.request()))
        await latch.release()
        await read.value
        // then
        #expect(second.id != first.id)
        #expect(harness.repository.state(for: harness.request()) == second)
        #expect(second.check == .notChecked)
    }

    @Test func givenEarlierUnknownAndAdmittedSuccessorWithError_whenSuccessorBridgeRecorded_thenNextSourceCanBeChosen() async throws {
        // given
        let harness = ContinuationHarness(runner: ContinuationRunner(output: continuationOutput(task: nil)),
                                          pages: ContinuationPages([.success(continuationPage(["next"])),
                                                                    .success(continuationPage(["other"], source: "next"))]))
        _ = await harness.repository.start(harness.request())
        let first = try #require(harness.repository.state(for: harness.request()))
        await harness.repository.check(attemptID: first.id)
        await harness.runner.setOutput(continuationOutput(error: "fixture", exit: 1))
        _ = await harness.repository.start(harness.request("next"))
        let second = try #require(harness.repository.state(for: harness.request("next")))
        await harness.repository.check(attemptID: second.id)
        // when
        await harness.runner.setOutput(continuationOutput())
        let result = await harness.repository.start(harness.request("other"))
        // then
        guard case .started = result else { Issue.record("Latest admitted source supplies a healthy one-hop bridge"); return }
        #expect(harness.repository.state(for: harness.request())?.outcome == first.outcome)
        #expect(await harness.repository.start(harness.request()) == .existing(first.id))
    }

    @Test func givenRepeatedHealthyChecksExceedProofCapacity_whenChecked_thenExistingProofIsRetainedAndNewProofIsInconclusive() async throws {
        // given
        let pages = (0 ..< 5).map { index in
            continuationPage((0 ..< 100).map { "edge-\(index)-\($0)" })
        }
        let harness = ContinuationHarness(pages: ContinuationPages(pages.map { .success($0) }))
        _ = await harness.repository.start(harness.request())
        let first = try #require(harness.repository.state(for: harness.request()))
        for _ in 0 ..< 4 { await harness.repository.check(attemptID: first.id) }
        // when
        await harness.repository.check(attemptID: first.id)
        // then
        let current = try #require(harness.repository.state(for: harness.request()))
        #expect(current.recordedSuccessorTaskIDs.count == 400)
        #expect(current.recordedSuccessorTaskIDs.contains("edge-0-0"))
        #expect(!current.recordedSuccessorTaskIDs.contains("edge-4-0"))
        #expect(current.check == .inconclusive)
        #expect(current.outcome == first.outcome)
    }
}
