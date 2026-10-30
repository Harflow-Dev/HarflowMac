import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouRoundTwoTests

@Suite struct NeedsYouRoundTwoTests {
    private func withDeadline(_ request: CallerApprovalRequest, _ date: Date) -> CallerApprovalRequest {
        var raw = request.raw
        raw["deadline"] = .number(date.timeIntervalSince1970)
        return CallerApprovalRequest(raw: raw)
    }

    @Test func givenARootWithMoreChildSourcesThanOnePassCanRead_whenPassesRun_thenItProgressesAndReadsEachChildOnce() async {
        // given
        let children = (0 ..< 40).map { String(format: "c%02d", $0) }
        let entries = children.map { inputEntry(run: $0, decision: "d-\($0)", path: ["w1", $0], kind: "usage_limit") }
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "d-c00", inputs: entries)
        for child in children { fake.statuses[child] = ["workflow_run_id": .string(child)] }
        let sut = makeSUT(fake)
        // when
        var counts: [Int] = []
        for _ in 0 ..< 8 where counts.last != 40 {
            await sut.runPass()
            counts.append(sut.snapshot.items.count)
        }
        // then
        #expect(counts.last == 40 && (counts.first ?? 0) < 40)
        #expect(zip(counts, counts.dropFirst()).allSatisfy { $0 < $1 || $0 == 40 })
        #expect(children.allSatisfy { child in fake.calls.filter { $0 == "status:\(child)" }.count == 1 })
    }

    @Test func givenManyRootsWithPermanentlyFailingChildren_whenPassesRun_thenHealthyLaterRootsAreStillReached() async {
        // given — more failing roots than one pass reads, sorted before the healthy ones.
        let fake = FakeNeedsYouEngine()
        let failing = (0 ..< 14).map { String(format: "a%02d", $0) }
        let healthy = (0 ..< 3).map { String(format: "z%02d", $0) }
        fake.headers = (failing + healthy).map { rootHeader($0) }
        for id in failing {
            let entry = inputEntry(run: "child-\(id)", decision: "d-\(id)", path: [id, "child-\(id)"], kind: "usage_limit")
            fake.statuses[id] = treeRoot(id, selected: "d-\(id)", inputs: [entry])
        }
        for id in healthy { fake.statuses[id] = treeRoot(id, selected: "d", inputs: [inputEntry(run: id, decision: "d")]) }
        fake.failingStatuses = Set(failing.map { "child-\($0)" })
        let sut = makeSUT(fake)
        // when
        for _ in 0 ..< 5 { await sut.runPass() }
        // then
        #expect(Set(sut.snapshot.items.map(\.rootRunID)) == Set(healthy))
        #expect(sut.snapshot.phase == .ready)
    }

    @Test func givenDetailFetchedEarlyThatExpiresBeforeListingCompletes_whenPublished_thenItIsNeitherListedNorNotified() async {
        // given — 40 rows need more than one pass; the first row's deadline passes in between.
        let scheduler = CapturingScheduler(now: Date())
        let soon = scheduler.now().addingTimeInterval(30)
        let later = scheduler.now().addingTimeInterval(100_000)
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1", awaiting: 40)]
        let rows = (0 ..< 40).map { withDeadline(approval(id: "r\($0)"), $0 == 0 ? soon : later) }
        fake.approvalRows["t1"] = rows
        for row in rows { fake.approvalDetails[row.id] = row }
        let sut = makeSUT(fake, scheduler: scheduler)
        let appeared = LockedBox<[String]>([])
        let token = sut.eventsPublisher().sink { event in if case .appeared(let item, _) = event { appeared.mutate { $0.append(item.id) } } }
        await sut.runPass()
        #expect(fake.calls.contains("approvalGet:r0") && sut.snapshot.items.isEmpty)
        // when
        scheduler.advance(to: scheduler.now().addingTimeInterval(60))
        for _ in 0 ..< 6 where sut.snapshot.items.count < 39 { await sut.runPass() }
        // then
        #expect(sut.snapshot.items.count == 39 && !sut.snapshot.items.map(\.id).contains("approval:t1:r0"))
        #expect(!appeared.value.contains("approval:t1:r0"))
        token.cancel()
    }

    @Test func givenAnAbsentApprovalSummary_whenPassRuns_thenTheTaskIsUnreadableAndItsApprovalWithdrawnNotResolved() async {
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
        // when — the same task now reports no summary at all.
        fake.tasks = [TaskInfo(.object(["task_id": .string("t1"), "status": .string("running"), "backend": .string("claude")]))!]
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.unreadableSourceCount == 1)
        #expect(sut.snapshot.withdrawn.map(\.id) == ["approval:t1:r1"] && resolved.value == 0)
        token.cancel()
    }

    @Test func givenAListingThatShiftsAcrossPages_whenAcquired_thenARepeatedRequestIsKeptOnce() async {
        // given
        let first = approval(id: "r1"), second = approval(id: "r2"), third = approval(id: "r3")
        let fake = FakeNeedsYouEngine()
        fake.tasks = [awaitingTask("t1", awaiting: 3)]
        for row in [first, second, third] { fake.approvalDetails[row.id] = row }
        fake.approvalPageOverride = { cursor in
            cursor == nil
                ? CallerApprovalPage(requests: [first, second], nextCursor: "1", total: 3)
                : CallerApprovalPage(requests: [second, third], nextCursor: nil, total: 3)
        }
        let sut = makeSUT(fake)
        // when
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.map(\.id).sorted() == ["approval:t1:r1", "approval:t1:r2", "approval:t1:r3"])
        #expect(fake.calls.filter { $0 == "approvalGet:r2" }.count == 1)
    }
}
