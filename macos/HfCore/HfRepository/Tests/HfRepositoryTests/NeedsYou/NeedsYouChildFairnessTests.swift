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
        // given — 50 failing children come first, 10 healthy ones last; one visit reads about 20.
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

    @Test func givenChildAdvancingToAnotherDecision_whenPassesRun_thenTheNewDecisionUsesItsOwnRecovery() async throws {
        // given — an oversized root keeps persisted child reads between visits; child "x" starts at decision A.
        let others = (1 ..< 30).map { String(format: "c%02d", $0) }
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
        // when — the child moves on to decision B while the root is still being read across passes.
        fake.statuses["w1"] = treeRoot("w1", selected: "dB", inputs: entries(decision: "dB"))
        fake.statuses["x"] = ["workflow_run_id": .string("x"), "usage_limit_recovery": recovery("dB", "answer-b")]
        for _ in 0 ..< 3 { await sut.runPass() }
        // then
        let item = try #require(sut.snapshot.items.first { $0.decisionID == "dB" })
        #expect(item.offeredAnswers == ["answer-b"])
        #expect(!sut.snapshot.items.contains { $0.decisionID == "dA" })
    }
}
