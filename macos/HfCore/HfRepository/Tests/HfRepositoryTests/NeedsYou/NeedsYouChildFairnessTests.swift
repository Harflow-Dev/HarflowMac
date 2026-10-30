import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouChildFairnessTests

@Suite struct NeedsYouChildFairnessTests {
    private func recovery(_ decision: String, _ answer: String) -> JSONValue {
        .object(["decision_id": .string(decision), "choices": .array([.object(["answer": .string(answer)])])])
    }

    @Test func givenOversizedRootWithFailingEarlyChildren_whenPassesRun_thenTheHealthyTailIsPublishedWithinBoundedPasses() async {
        // given — 50 failing children come first, 10 healthy ones last; a visit's launch share covers only part of them, so the root spans passes.
        let children = (0 ..< 60).map { String(format: "c%02d", $0) }
        let entries = children.map { inputEntry(run: $0, decision: "d-\($0)", path: ["w1", $0], kind: "usage_limit") }
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "d-c00", inputs: entries)
        for child in children { fake.statuses[child] = ["workflow_run_id": .string(child)] }
        fake.failingStatuses = Set(children.prefix(50))
        let sut = makeSUT(fake)
        // when
        for _ in 0 ..< 4 { await sut.runPass() }
        // then
        let published = Set(sut.snapshot.items.map(\.decisionID))
        #expect(children.suffix(10).allSatisfy { published.contains("d-\($0)") })
    }

    @Test func givenChildAdvancingToAnotherDecisionInARootSpanningPasses_whenPassesRun_thenAPublishedItemNeverUsesTheStaleRecovery() async {
        // given — 60 entries, so the root spans passes and persisted child reads are in play; child "x" is first.
        let others = (1 ..< 60).map { String(format: "c%02d", $0) }
        func entries(decision: String) -> [JSONValue] {
            [inputEntry(run: "x", decision: decision, path: ["w1", "x"], kind: "usage_limit")]
                + others.map { inputEntry(run: $0, decision: "d-\($0)", path: ["w1", $0], kind: "usage_limit") }
        }
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "dA", inputs: entries(decision: "dA"))
        fake.statuses["x"] = ["workflow_run_id": .string("x"), "usage_limit_recovery": recovery("dA", "answer-a")]
        for child in others { fake.statuses[child] = ["workflow_run_id": .string(child)] }
        let sut = makeSUT(fake)
        await sut.runPass()
        #expect(sut.snapshot.items.first { $0.decisionID == "dA" }?.offeredAnswers == ["answer-a"])
        #expect(sut.snapshot.items.count < 60, "the root must still be incomplete after one pass")
        // when — the child moves on to decision B while the root is still being read across passes.
        fake.statuses["w1"] = treeRoot("w1", selected: "dB", inputs: entries(decision: "dB"))
        fake.statuses["x"] = ["workflow_run_id": .string("x"), "usage_limit_recovery": recovery("dB", "answer-b")]
        var published: [[String]?] = []
        for _ in 0 ..< 8 {
            await sut.runPass()
            if let item = sut.snapshot.items.first(where: { $0.decisionID == "dB" }) { published.append(item.offeredAnswers) }
        }
        // then — B appears (the rotating cursor reaches it) and always with B's own recovery, never A's cached status.
        #expect(!published.isEmpty)
        #expect(published.allSatisfy { $0 == ["answer-b"] })
        #expect(!sut.snapshot.items.contains { $0.decisionID == "dA" })
    }
}
