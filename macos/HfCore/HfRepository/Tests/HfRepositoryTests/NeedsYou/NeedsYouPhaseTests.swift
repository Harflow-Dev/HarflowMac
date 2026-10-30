import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouPhaseTests

@Suite struct NeedsYouPhaseTests {
    @Test func givenAPermanentlyUnreadableRoot_whenANewRootAppears_thenPhaseIsReadyAndTheNewRootNotifies() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("bad")]
        fake.failingStatuses = ["bad"]
        let sut = makeSUT(fake)
        let flags = LockedBox<[Bool]>([])
        let token = sut.eventsPublisher().sink { event in
            if case .appeared(_, let baseline) = event { flags.mutate { $0.append(baseline) } }
        }
        await sut.runPass()
        #expect(sut.snapshot.phase == .ready && sut.snapshot.unreadableSourceCount == 1)
        // when
        fake.headers.append(rootHeader("good"))
        fake.statuses["good"] = treeRoot("good", selected: "d", inputs: [inputEntry(run: "good", decision: "d")])
        await sut.runPass()
        // then
        #expect(flags.value == [false])
        #expect(sut.snapshot.items.map(\.id) == ["input:good:d"])
        token.cancel()
    }

    @Test func givenAnUnsupportedRoot_whenPassRuns_thenPhaseIsReady() async {
        // given
        var status = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")])
        status["interaction_state"] = nil
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = status
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.phase == .ready && sut.snapshot.workflowInputsUnsupported)
    }

    @Test func givenABatchFailure_whenPassRuns_thenPhaseIsReadyAndALaterApprovalNotifies() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1")]
        fake.taskBatchFails = true
        let sut = makeSUT(fake)
        let flags = LockedBox<[Bool]>([])
        let token = sut.eventsPublisher().sink { event in
            if case .appeared(_, let baseline) = event { flags.mutate { $0.append(baseline) } }
        }
        await sut.runPass()
        #expect(sut.snapshot.phase == .ready)
        // when
        fake.taskBatchFails = false
        let row = approval()
        fake.approvalRows["t1"] = [row]
        fake.approvalDetails["r1"] = row
        await sut.runPass()
        // then
        #expect(flags.value == [false])
        token.cancel()
    }

    @Test func givenDeferredSources_whenLaterPassesAttemptThem_thenPhaseBecomesReady() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = (0 ..< 30).map { rootHeader(String(format: "w%02d", $0)) }
        for header in fake.headers {
            let id = header["workflow_run_id"]!.stringValue!
            fake.statuses[id] = treeRoot(id, selected: "d", inputs: [inputEntry(run: id, decision: "d")])
        }
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        let first = sut.snapshot
        await sut.runPass()
        await sut.runPass()
        // then
        #expect(first.phase == .loading && first.deferredSourceCount > 0)
        #expect(sut.snapshot.phase == .ready)
    }
}
