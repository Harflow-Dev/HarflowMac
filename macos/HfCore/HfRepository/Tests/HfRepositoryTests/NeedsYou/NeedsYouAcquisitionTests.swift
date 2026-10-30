import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouAcquisitionTests

@Suite struct NeedsYouAcquisitionTests {
    @Test func givenUncertainLedgerReportingZeroAwaiting_whenPassRuns_thenTheTaskIsUnreadableNotEmpty() async {
        // given — the v0.0.5 shape: awaiting 0 together with the uncertainty marker and an error.
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1", awaiting: 0, extra: ["interaction_state": .string("approval_state_uncertain"),
                                                              "error": .string("Approval ledger unavailable")])]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.unreadableSourceCount == 1 && sut.snapshot.items.isEmpty)
    }

    @Test func givenUncertainLedgerThenRecovered_whenPassesRun_thenHeldApprovalIsWithdrawnNotResolved() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        let row = approval()
        fake.tasks = [awaitingTask("t1")]
        fake.approvalRows["t1"] = [row]
        fake.approvalDetails["r1"] = row
        let sut = makeSUT(fake)
        let resolved = LockedBox(0)
        let token = sut.eventsPublisher().sink { event in if case .resolved = event { resolved.mutate { $0 += 1 } } }
        await sut.runPass()
        #expect(sut.snapshot.items.count == 1)
        // when
        fake.tasks = [awaitingTask("t1", awaiting: 0, extra: ["error": .string("unavailable")])]
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.withdrawn.map(\.id) == ["approval:t1:r1"] && resolved.value == 0)
        token.cancel()
    }

    @Test func givenManyApprovalTasks_whenPassesRun_thenProgressIsMonotonicAndComplete() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.tasks = (0 ..< 100).map { awaitingTask("t\($0)") }
        for index in 0 ..< 100 {
            let row = approval(task: "t\(index)", id: "r\(index)")
            fake.approvalRows["t\(index)"] = [row]
            fake.approvalDetails["r\(index)"] = row
        }
        let sut = makeSUT(fake)
        // when
        var counts: [Int] = []
        for _ in 0 ..< 120 where counts.last != 100 {
            await sut.runPass()
            counts.append(sut.snapshot.items.count)
        }
        // then
        #expect(counts.last == 100)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(counts.dropLast().allSatisfy { $0 < 100 })
    }

    @Test func givenManyRootCandidates_whenPassesRun_thenApprovalTasksAreNotStarved() async {
        // given
        let fake = FakeNeedsYouEngine()
        fake.headers = (0 ..< 40).map { rootHeader(String(format: "w%02d", $0)) }
        for header in fake.headers {
            let id = header["workflow_run_id"]!.stringValue!
            fake.statuses[id] = treeRoot(id, selected: "d", inputs: [inputEntry(run: id, decision: "d")])
        }
        fake.tasks = (0 ..< 5).map { awaitingTask("t\($0)") }
        for index in 0 ..< 5 {
            let row = approval(task: "t\(index)", id: "r\(index)")
            fake.approvalRows["t\(index)"] = [row]
            fake.approvalDetails["r\(index)"] = row
        }
        let sut = makeSUT(fake)
        // when
        for _ in 0 ..< 4 { await sut.runPass() }
        // then
        #expect(sut.snapshot.items.filter { $0.kind == .approval }.count == 5)
    }

    @Test func givenLongApprovalListing_whenPassesRun_thenCursorsPersistAndEveryRequestIsReached() async {
        // given — more retained records than one pass can list or fetch.
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1", awaiting: 70)]
        fake.approvalPageSize = 16
        let rows = (0 ..< 70).map { approval(id: "r\($0)") }
        fake.approvalRows["t1"] = rows
        for row in rows { fake.approvalDetails[row.id] = row }
        let sut = makeSUT(fake)
        // when
        for _ in 0 ..< 12 where sut.snapshot.items.count < 70 { await sut.runPass() }
        // then
        #expect(sut.snapshot.items.count == 70)
        #expect(fake.calls.filter { $0 == "approvalList:t1" }.count == 5)
        #expect(fake.calls.filter { $0 == "approvalGet:r69" }.count == 1)
    }

    @Test func givenCapabilityProbeFails_whenCallerOwnedApprovalIsRead_thenTheTaskIsUnreadable() async {
        // given
        let fake = FakeNeedsYouEngine()
        let row = approval(owner: "caller")
        fake.tasks = [awaitingTask("t1")]
        fake.approvalRows["t1"] = [row]
        fake.approvalDetails["r1"] = row
        fake.capabilityFails = true
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.unreadableSourceCount == 1)
    }

    @Test func givenReusedApprovalPastItsDeadline_whenPassRepeats_thenItIsNoLongerListed() async {
        // given
        let fake = FakeNeedsYouEngine()
        let scheduler = CapturingScheduler(now: Date())
        var raw = approval().raw
        raw["deadline"] = .number(scheduler.now().addingTimeInterval(30).timeIntervalSince1970)
        let row = CallerApprovalRequest(raw: raw)
        fake.tasks = [awaitingTask("t1")]
        fake.approvalRows["t1"] = [row]
        fake.approvalDetails["r1"] = row
        let sut = makeSUT(fake, scheduler: scheduler)
        await sut.runPass()
        #expect(sut.snapshot.items.count == 1)
        // when
        scheduler.advance(to: scheduler.now().addingTimeInterval(60))
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty)
        #expect(fake.calls.filter { $0 == "approvalGet:r1" }.count == 1)
    }

    @Test func givenOneChildReadFails_whenPassRuns_thenOnlyThatChildsEntriesAreWithheldNotResolved() async throws {
        // given
        let good = inputEntry(run: "ok", decision: "dok", path: ["w1", "ok"], kind: "usage_limit")
        let bad = inputEntry(run: "bad", decision: "dbad", path: ["w1", "bad"], kind: "usage_limit")
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "dok", inputs: [good, bad])
        fake.statuses["ok"] = ["workflow_run_id": .string("ok"),
                               "usage_limit_recovery": .object(["decision_id": .string("dok"), "choices": .array([.object(["answer": .string("retry")])])])]
        fake.statuses["bad"] = ["workflow_run_id": .string("bad")]
        let sut = makeSUT(fake)
        let resolved = LockedBox(0)
        let token = sut.eventsPublisher().sink { event in if case .resolved = event { resolved.mutate { $0 += 1 } } }
        await sut.runPass()
        #expect(sut.snapshot.items.count == 2)
        // when
        fake.failingStatuses = ["bad"]
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.id) == ["input:w1:dok"])
        #expect(sut.snapshot.withdrawn.map(\.id) == ["input:w1:dbad"])
        #expect(sut.snapshot.unreadableSourceCount == 1 && resolved.value == 0)
        token.cancel()
    }

    @Test func givenTwoDecisionsFromOneChild_whenPassRuns_thenTheChildIsReadOnce() async {
        // given
        let first = inputEntry(run: "c", decision: "d1", path: ["w1", "c"], kind: "usage_limit")
        let second = inputEntry(run: "c", decision: "d2", path: ["w1", "c"], kind: "usage_limit")
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "d1", inputs: [first, second])
        fake.statuses["c"] = ["workflow_run_id": .string("c")]
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(fake.calls.filter { $0 == "status:c" }.count == 1)
        #expect(sut.snapshot.items.count == 2)
    }

    @Test func givenRecoveryPreSendReadFails_whenAnswered_thenItIsAFailureNotAChangedCheckpoint() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        let attention = JSONValue.object(["workflow_run_id": .string("w1"), "status": .string("needs_attention"), "reason": .string("limit"),
                                          "path": .array([.string("w1")]), "waiting_since": .number(5)])
        fake.headers = [rootHeader("w1", status: "needs_attention")]
        fake.statuses["w1"] = treeRoot("w1", status: "needs_attention", attention: [attention], extra: ["attention_reason": .string("limit")])
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        fake.failingStatuses = ["w1"]
        // when
        let outcome = await sut.answer(item, text: "go", additionalAttempts: 1)
        // then
        #expect(outcome == .failed("Harflow could not re-check this request. Try again."))
        #expect(fake.resumes.isEmpty)
    }
}
