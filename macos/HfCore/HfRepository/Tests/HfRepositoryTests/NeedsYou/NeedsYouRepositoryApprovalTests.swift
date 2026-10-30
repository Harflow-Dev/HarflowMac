import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouRepositoryApprovalTests

@Suite struct NeedsYouRepositoryApprovalTests {
    private func engine(owner: String = "monitor", capability: Bool = true) -> FakeNeedsYouEngine {
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1")]
        let row = approval(owner: owner)
        fake.approvalRows["t1"] = [row]
        fake.approvalDetails["r1"] = row
        fake.capability = capability
        return fake
    }

    @Test func givenMonitorOwnedApproval_whenPassRuns_thenItIsListedFromListThenGet() async throws {
        // given
        let fake = engine()
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(item.id == "approval:t1:r1" && item.kind == .approval && item.text == "Bash: ls" && item.approval?.raw["action"] != nil)
        #expect(fake.calls.contains("approvalList:t1") && fake.calls.contains("approvalGet:r1"))
    }

    @Test func givenCallerOwnedWithoutCapability_whenPassRuns_thenItIsExcluded() async {
        // given
        let sut = makeSUT(engine(owner: "caller", capability: false))
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty)
    }

    @Test func givenCallerOwnedWithCapability_whenPassRuns_thenItIsListed() async {
        // given
        let sut = makeSUT(engine(owner: "caller", capability: true))
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.count == 1)
    }

    @Test func givenHeldApprovalWithSameRevision_whenPassRepeats_thenNoSecondGet() async {
        // given
        let fake = engine()
        let sut = makeSUT(fake)
        await sut.runPass()
        // when
        await sut.runPass()
        // then
        #expect(fake.calls.filter { $0 == "approvalGet:r1" }.count == 1)
    }

    @Test func givenIncompleteSummary_whenPassRuns_thenTaskIsUnreadable() async {
        // given
        let fake = engine()
        fake.tasks = [awaitingTask("t1", extra: ["interaction_state": .string("approval_state_uncertain")])]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.unreadableSourceCount == 1)
    }

    @Test func givenBatchUnsupported_whenPassRuns_thenApprovalsAreUnreadableForThePass() async {
        // given
        let fake = engine()
        fake.taskBatchFails = true
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.unreadableSourceCount == 1)
    }

    @Test func givenMoreThanOneHundredTasks_whenPassRuns_thenAllAreChecked() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.tasks = (0 ..< 130).map { awaitingTask("t\($0)", awaiting: 0) }
        fake.tasks[125] = awaitingTask("t125")
        let row = approval(task: "t125")
        fake.approvalRows["t125"] = [row]
        fake.approvalDetails["r1"] = row
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.id) == ["approval:t125:r1"])
        #expect(fake.calls.filter { $0 == "batch" }.count == 2)
    }

    @Test func givenApprovalChangedBeforeSend_whenResponding_thenChangedAndNothingSent() async throws {
        // given
        let fake = engine()
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        fake.approvalDetails["r1"] = approval(revision: 2, command: "rm -rf build")
        // when
        let outcome = await sut.respond(item, decision: "approve")
        // then
        if case .changed(let refreshed) = outcome { #expect(refreshed?.text == "Bash: rm -rf build") } else { Issue.record("expected .changed") }
        #expect(!fake.calls.contains("respond:r1"))
    }

    @Test func givenUnconfirmedResponse_whenResponding_thenFailsWithoutSettling() async throws {
        // given
        let fake = engine()
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        // when
        let outcome = await sut.respond(item, decision: "approve")
        // then
        if case .failed = outcome {} else { Issue.record("an echo of the pending request does not confirm a decision") }
        #expect(sut.snapshot.items.count == 1)
    }
}
