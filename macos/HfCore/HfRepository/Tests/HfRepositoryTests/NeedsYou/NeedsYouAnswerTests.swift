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
        #expect(fake.resumes.first?.checkpoint == nil)
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

    private func recovery(_ fake: FakeNeedsYouEngine, reason: String, checkpoint: String = "attention:w1:checkpoint-1") {
        let attention = JSONValue.object(["workflow_run_id": .string("w1"), "status": .string("needs_attention"), "reason": .string(reason),
                                          "path": .array([.string("w1")]), "waiting_since": .number(5),
                                          "attention_checkpoint_id": .string(checkpoint)])
        fake.headers = [rootHeader("w1", status: "needs_attention")]
        fake.statuses["w1"] = treeRoot("w1", status: "needs_attention", attention: [attention], extra: ["attention_reason": .string(reason),
                                                                                                      "attention_checkpoint_id": .string(checkpoint)])
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
        #expect(fake.resumes.first?.checkpoint == "attention:w1:checkpoint-1")
    }

    @Test func givenRecoveryCheckpointChanged_whenAnswered_thenStaleAndNothingSent() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        recovery(fake, reason: "limit")
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        recovery(fake, reason: "a different failure", checkpoint: "attention:w1:checkpoint-2")
        fake.resumeError = .refused(code: "attention_checkpoint_stale", message: "The checkpoint changed")
        // when
        let outcome = await sut.answer(item, text: "go on", additionalAttempts: 1)
        await sut.runPass()
        // then
        #expect(outcome == .stale(NeedsYouAnswerOutcome.changedMessage))
        #expect(fake.resumes.first?.checkpoint == item.attentionCheckpointID)
        #expect(sut.snapshot.items.first?.id != item.id)
    }

    @Test func givenLegacyRecoveryWithoutCheckpoint_whenAnswered_thenRefusesWithoutSending() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        recovery(fake, reason: "limit")
        let sut = makeSUT(fake)
        await sut.runPass()
        var legacyItem = try #require(sut.snapshot.items.first)
        legacyItem.attentionCheckpointID = nil
        // when
        let outcome = await sut.answer(legacyItem, text: "go on", additionalAttempts: 1)
        // then
        if case .failed = outcome {} else { Issue.record("expected unavailable checkpoint refusal") }
        #expect(fake.resumes.isEmpty)
    }

    @Test func givenStaleCheckpointRefusal_whenAnswered_thenRefreshesAndRetainsRequest() async throws {
        // given
        let fake = FakeNeedsYouEngine()
        recovery(fake, reason: "limit")
        let sut = makeSUT(fake)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        fake.resumeError = .refused(code: "attention_checkpoint_stale", message: "The checkpoint changed")
        // when
        let outcome = await sut.answer(item, text: "go on", additionalAttempts: 1)
        // then
        if case .stale = outcome {} else { Issue.record("expected stale checkpoint classification") }
        #expect(sut.snapshot.items.first?.attentionCheckpointID == item.attentionCheckpointID)
        #expect(fake.calls.contains("workflowPage"))
        #expect(fake.resumes.count == 1)
    }

    @Test func givenARefusalWithCode_whenClassified_thenFailedCarriesDisplayMessageAndCode() {
        // given
        let error = ToolError.refused(code: "session_busy", message: "Another run holds it")
        // when
        let outcome = NeedsYouAnswerOutcome.classify(error)
        // then
        #expect(outcome == .failed(message: "Another run holds it", code: "session_busy", legacyText: error.message))
        #expect(error.message.contains("Refused: another run or takeover"))
    }

    @Test func givenAnEmptyRefusalMessage_whenClassified_thenMessageIsRefusedAndLegacyTextIsToday() {
        // given
        let error = ToolError.refused(code: "some_code", message: "")
        // when
        let outcome = NeedsYouAnswerOutcome.classify(error)
        // then
        #expect(outcome == .failed(message: "Refused.", code: "some_code", legacyText: "Refused (some_code)."))
    }

    @Test func givenWorkflowErrorRefusal_whenClassified_thenCodeIsNil() {
        // given
        let error = ToolError.refused(code: "workflow_error", message: "Something else entirely")
        // when
        let outcome = NeedsYouAnswerOutcome.classify(error)
        // then
        #expect(outcome == .failed(message: "Something else entirely", code: nil, legacyText: "Something else entirely"))
    }

    @Test func givenANonRefusalError_whenClassified_thenCodeIsNilAndTextsAreTheMessage() {
        // given
        let error = ToolError.launchFailed(tool: "harflow-ctl", detail: "no such file")
        // when
        let outcome = NeedsYouAnswerOutcome.classify(error)
        // then
        #expect(outcome == .failed(message: error.message, code: nil, legacyText: error.message))
    }

    @Test func givenTimedOutResume_whenAnswered_thenUnknownAndOneInvocation() async {
        // given
        let (sut, fake, item) = await question()
        fake.resumeError = .timedOut(tool: "harflow-ctl", seconds: 30)
        // when
        let outcome = await sut.answer(item, text: "x", additionalAttempts: nil)
        // then
        #expect(outcome == .unknown(ToolError.timedOut(tool: "harflow-ctl", seconds: 30).message))
        #expect(fake.resumes.count == 1)
        #expect(sut.snapshot.items.count == 1)
    }

    @Test func givenUnknownOutcomeResume_whenAnswered_thenUnknown() async {
        // given
        let (sut, fake, item) = await question()
        fake.resumeError = .unknownOutcome(message: "No answer")
        // when
        let outcome = await sut.answer(item, text: "x", additionalAttempts: nil)
        // then
        #expect(outcome == .unknown("No answer"))
        #expect(fake.resumes.count == 1)
    }

    @Test func givenOwnershipVariants_whenSettledNote_thenTextsMatchThePreviousMapper() {
        // given
        func item(_ ownership: NeedsYouItem.Ownership, kind: NeedsYouItem.Kind = .question, root: String = "w1") -> NeedsYouItem {
            var value = NeedsYouItem(id: "i", kind: kind, runTitle: "Run", text: "t", ownership: ownership, startedBy: "Original caller")
            value.rootRunID = root
            return value
        }
        // when / then
        #expect(item(.init(owner: "caller", callerEnded: false, engineNote: "", handover: nil)).settledNote == "Run no longer needs you.")
        #expect(item(.init(owner: "caller", callerEnded: true, engineNote: "", handover: nil)).settledNote
            == "Harflow now owns this run. The original caller can no longer answer it, and Run no longer needs you.")
        #expect(item(.init(owner: "caller", callerEnded: false, engineNote: "", handover: nil, sharedAnswering: true)).settledNote
            == "The engine used the first answer. Ownership is unchanged.")
        #expect(item(.init(owner: "caller", callerEnded: false, engineNote: "", handover: nil), kind: .approval, root: "").settledNote
            == "Harflow sent your decision to the engine, and Run no longer needs you.")
    }
}
