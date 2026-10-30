import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - NeedsYouAnswerTests

@Suite struct NeedsYouAnswerTests {
    private func question(offered: [String]? = nil) async -> (NeedsYouRepositoryImpl, FakeNeedsYouEngine, NeedsYouItem) {
        let fake = FakeNeedsYouEngine()
        fake.headers = [rootHeader("w1")]
        fake.statuses["w1"] = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")])
        let sut = makeSUT(fake)
        await sut.runPass()
        var item = sut.snapshot.items[0]
        item.offeredAnswers = offered
        return (sut, fake, item)
    }

    @Test func givenQuestion_whenAnswered_thenResumeTargetsRootWithDecisionAndItemIsSuppressed() async {
        // given
        let (sut, fake, item) = await question()
        let events = LockedBox<[NeedsYouEvent]>([])
        let token = sut.eventsPublisher().sink { event in events.mutate { $0.append(event) } }
        // when
        let outcome = await sut.answer(item, text: " staging ", additionalAttempts: nil)
        await sut.runPass()
        // then
        #expect(outcome == .accepted)
        #expect(fake.resumes.first?.root == "w1" && fake.resumes.first?.decision == "d1" && fake.resumes.first?.text == "staging")
        #expect(sut.snapshot.items.isEmpty)
        #expect(events.value.contains(.resolved("input:w1:d1")))
        token.cancel()
    }

    @Test func givenUsageLimitItem_whenAnswerIsNotOffered_thenNothingIsSent() async {
        // given
        let (sut, fake, item) = await question(offered: ["retry"])
        // when
        let outcome = await sut.answer(item, text: "something else", additionalAttempts: nil)
        // then
        if case .failed = outcome {} else { Issue.record("expected .failed") }
        #expect(fake.resumes.isEmpty)
    }

    @Test func givenRefusal_whenAnswered_thenItIsClassifiedAndTheItemStays() async {
        // given
        let (sut, fake, item) = await question()
        fake.resumeError = .refused(code: "workflow_error", message: "Workflow interaction belongs to its original caller; caller is alive")
        // when
        let outcome = await sut.answer(item, text: "x", additionalAttempts: nil)
        // then
        #expect(outcome == .callerReturned("The caller is answering this again."))
        #expect(sut.snapshot.items.count == 1)
    }

    @Test(arguments: [
        ("Workflow interaction belongs to its original caller; caller is alive", "returned"),
        ("Workflow interaction belongs to its original caller; caller is unknown", "stale"),
        ("Workflow interaction belongs to its original caller", "stale"),
        ("The forwarded question moved on", "stale"),
        ("Input decision_id 'x' is not currently available", "stale"),
        ("Workflow is terminal or cancelling", "stale"),
        ("Something else entirely", "failed")
    ])
    func givenEngineMessage_whenClassified_thenOutcomeMatches(message: String, expected: String) {
        // given
        let error = ToolError.refused(code: "workflow_error", message: message)
        // when
        let outcome = NeedsYouAnswerOutcome.classify(error)
        // then
        switch (outcome, expected) {
        case (.callerReturned, "returned"), (.stale, "stale"), (.failed, "failed"): break
        default: Issue.record("unexpected outcome \(outcome) for \(message)")
        }
    }

    @Test func givenNotCurrentApprovalRefusal_whenClassified_thenStale() {
        // given
        let error = ToolError.structuredRefusal(code: "approval_error", message: "stale", data: ["reason": .string("not_current")])
        // then
        if case .stale = NeedsYouAnswerOutcome.classify(error) {} else { Issue.record("expected .stale") }
    }

    private func recovery(_ fake: FakeNeedsYouEngine, reason: String) {
        let attention = JSONValue.object(["workflow_run_id": .string("w1"), "status": .string("needs_attention"), "reason": .string(reason),
                                          "path": .array([.string("w1")]), "waiting_since": .number(5)])
        fake.headers = [rootHeader("w1", status: "needs_attention")]
        fake.statuses["w1"] = treeRoot("w1", status: "needs_attention", attention: [attention], extra: ["attention_reason": .string(reason)])
    }

    @Test func givenRecoveryUnchanged_whenAnswered_thenResumeSendsAttemptsWithoutDecision() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        recovery(fake, reason: "limit")
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        // when
        let outcome = await sut.answer(item, text: "go on", additionalAttempts: 2)
        // then
        #expect(outcome == .accepted)
        #expect(fake.resumes.first?.decision == nil && fake.resumes.first?.attempts == 2)
    }

    @Test func givenRecoveryCheckpointChanged_whenAnswered_thenStaleAndNothingSent() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        recovery(fake, reason: "limit")
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        recovery(fake, reason: "a different failure")
        // when
        let outcome = await sut.answer(item, text: "go on", additionalAttempts: 1)
        await sut.runPass()
        // then
        #expect(outcome == .stale(NeedsYouAnswerOutcome.changedMessage))
        #expect(fake.resumes.isEmpty)
        #expect(sut.snapshot.items.first?.id != item.id)
    }
}
