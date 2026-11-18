import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowGoalDraftTests

@MainActor
struct WorkflowGoalDraftTests {
    private func runRaw(id: String = "run", revision: Int = 3, goal: String = "Verify.") -> [String: JSONValue] {
        ["workflow_run_id": .string(id), "status": .string("paused"), "interaction_owner": .string("monitor"),
         "can_revise_goal": .bool(true), "goal": .string(goal), "goal_revision": .number(Double(revision))]
    }

    /// A view model on a revisable run whose `revise-goal` throws `failure` when given and whose other reads return the run.
    /// The save task starts only after the test body yields, so edits made before the first `await` happen "while saving".
    private func makeVM(failure: Error? = nil) -> (sut: WorkflowVM, useCase: MockWorkflowUseCase) {
        let harness = WorkflowTests().makeVM()
        let raw = runRaw()
        let reads = ["run": raw, "other": runRaw(id: "other")]
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willProduce { name, _, positionals, _ in
            if name == "revise-goal", let failure { throw failure }
            return reads[positionals.first ?? "run"] ?? raw
        }
        harness.sut.selectedRun = WorkflowRunModel(raw: raw)
        return harness
    }

    @Test func givenRevisableRun_whenDraftIsOpenedAndEdited_thenEveryReaderSeesTheSameDraft() {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        let run = WorkflowRunModel(raw: runRaw())
        // when
        harness.sut.beginGoalDraft(run: run)
        harness.sut.updateGoalDraft("Verify everything.")
        harness.sut.beginGoalDraft(run: run)
        // then
        #expect(harness.sut.goalDraft?.text == "Verify everything.")
        #expect(harness.sut.goalDraft?.expectedRevision == 3)
        #expect(harness.sut.goalDraft?.runID == "run")
    }

    @Test func givenOpenDraft_whenRunChanges_thenDraftAndErrorAreCleared() {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.goalRevisionError = "x"
        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(id: "other"))
        // then
        #expect(harness.sut.goalDraft == nil)
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenFailedSave_whenCancelling_thenDraftAndErrorAreCleared() async {
        // given
        let harness = makeVM(failure: ToolError.refused(code: "stale", message: "Revision is stale."))
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.reviseGoal("New goal", runID: "run", expectedRevision: 3)
        await waitUntil { !harness.sut.isBusy && harness.sut.goalRevisionError != nil }
        // when
        harness.sut.cancelGoalDraft()
        // then
        #expect(harness.sut.goalDraft == nil)
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenSaveFails_whenSaving_thenErrorGoesToTheFormAndTheDraftIsKept() async {
        // given
        let harness = makeVM(failure: ToolError.refused(code: "stale", message: "Revision is stale."))
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("New goal")
        // when
        harness.sut.reviseGoal("New goal", runID: "run", expectedRevision: 3)
        await waitUntil { !harness.sut.isBusy && harness.sut.goalRevisionError != nil }
        // then
        #expect(harness.sut.goalRevisionError == "Revision is stale.")
        #expect(harness.sut.errorText == nil)
        #expect(harness.sut.goalDraft?.text == "New goal")
        harness.sut.updateGoalDraft("New goal, edited")
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenSaveSucceeds_whenSaving_thenDraftIsCleared() async {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("New goal")
        // when
        harness.sut.reviseGoal("New goal", runID: "run", expectedRevision: 3)
        await waitUntil { !harness.sut.isBusy }
        // then
        #expect(harness.sut.goalDraft == nil)
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenDelayedSave_whenCancelledAndReopened_thenStaleCompletionLeavesTheNewDraft() async {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("First")
        harness.sut.reviseGoal("First", runID: "run", expectedRevision: 3)
        // when
        harness.sut.cancelGoalDraft()
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("Second")
        await waitUntil { !harness.sut.isBusy }
        // then
        #expect(harness.sut.goalDraft?.text == "Second")
        #expect(harness.sut.goalDraft?.expectedRevision == 3, "A stale completion must not rebase the new session")
    }

    @Test func givenDelayedSave_whenRunChanges_thenCompletionChangesNothing() async {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.reviseGoal("First", runID: "run", expectedRevision: 3)
        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(id: "other"))
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw(id: "other")))
        await waitUntil { !harness.sut.isBusy }
        // then
        #expect(harness.sut.goalDraft?.runID == "other")
        #expect(harness.sut.goalDraft?.expectedRevision == 3)
        #expect(harness.sut.goalDraft?.text == "Verify.")
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenDelayedSave_whenTypingWhileSaving_thenEditsArePreservedOnTheNewRevision() async {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("First")
        harness.sut.reviseGoal("First", runID: "run", expectedRevision: 3)
        // when
        harness.sut.updateGoalDraft("First and more")
        await waitUntil { !harness.sut.isBusy }
        // then
        #expect(harness.sut.goalDraft?.text == "First and more")
        #expect(harness.sut.goalDraft?.expectedRevision == 4)
    }

    private func winnerRefusal() -> ToolError {
        let winner: JSONValue = .object(["interaction_id": .string("goal-1"), "workflow_run_id": .string("run"),
                                         "action": .string("revise_goal"), "answer": .string("Caller goal"),
                                         "answered_by": .string("caller"), "answered_at": .number(1793059200)])
        return ToolError.structuredRefusal(code: "workflow_error", message: "Already answered",
                                           data: ["code": .string("interaction_already_answered"), "interaction": winner])
    }

    @Test func givenCallerWinsRace_whenRevisingGoal_thenOutcomeAndLatestEditsAreRetainedForTheCard() async {
        // given
        let harness = makeVM(failure: winnerRefusal())
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("My goal")
        // when
        harness.sut.reviseGoal("My goal", runID: "run", expectedRevision: 3)
        harness.sut.updateGoalDraft("My goal, typed after submitting")
        await waitUntil { !harness.sut.isBusy && harness.sut.interactionOutcome != nil }
        // then
        #expect(harness.sut.interactionOutcome?.action == "revise_goal")
        #expect(harness.sut.interactionSavedDraft == "My goal, typed after submitting")
        #expect(harness.sut.goalRaceExpectedRevision == 3)
        #expect(harness.sut.goalDraft == nil)
        #expect(harness.sut.goalRevisionError == nil)
        let behind = WorkflowRunModel(raw: runRaw(revision: 3))
        let caught = WorkflowRunModel(raw: runRaw(revision: 4))
        let behindCard = harness.sut.goalAnsweredElsewhere(for: WorkflowGoalPresentation(run: behind))
        #expect(behindCard == nil, "A refresh that has not seen expected + 1 keeps the header copy")
        #expect(harness.sut.goalAnsweredElsewhere(for: WorkflowGoalPresentation(run: caught)) != nil)
        #expect(harness.sut.goalAnsweredElsewhere(for: WorkflowGoalPresentation(run: WorkflowRunModel(raw: runRaw(revision: 5)))) == nil)
    }

    @Test func givenLostRaceOnRunA_whenSwitchingToBAndBack_thenOutcomeIsStillShownSomewhere() async {
        // given
        let harness = makeVM(failure: winnerRefusal())
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.reviseGoal("My goal", runID: "run", expectedRevision: 3)
        await waitUntil { !harness.sut.isBusy && harness.sut.interactionOutcome != nil }
        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(id: "other"))
        let away = harness.sut.interactionOutcome
        harness.sut.selectedRun = WorkflowRunModel(raw: runRaw())
        // then
        #expect(away == nil)
        #expect(harness.sut.interactionOutcome != nil, "The outcome returns with its run")
        let backCard = harness.sut.goalAnsweredElsewhere(for: WorkflowGoalPresentation(run: WorkflowRunModel(raw: runRaw())))
        #expect(backCard == nil, "No card yet: the header keeps the copy")
        #expect(harness.sut.goalRaceExpectedRevision == 3)
    }

    @Test func givenStaleWinner_whenRunChangedOrDraftReopened_thenNothingIsApplied() async {
        // given
        for reopen in [false, true] {
            let harness = makeVM(failure: winnerRefusal())
            defer { harness.sut.didDisappear() }
            harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
            harness.sut.reviseGoal("My goal", runID: "run", expectedRevision: 3)
            // when
            if reopen {
                harness.sut.cancelGoalDraft()
                harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
            } else {
                harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(id: "other"))
            }
            await waitUntil { !harness.sut.isBusy }
            // then
            #expect(harness.sut.retainedInteractionOutcome == nil)
            #expect(harness.sut.interactionSavedDraft == nil)
            #expect(harness.sut.goalRaceExpectedRevision == nil)
            #expect((harness.sut.goalDraft != nil) == reopen)
        }
    }

    @Test func givenStaleFailure_whenRunChangedOrDraftReopened_thenNoErrorIsShown() async {
        // given
        for reopen in [false, true] {
            let harness = makeVM(failure: ToolError.refused(code: "stale", message: "Revision is stale."))
            defer { harness.sut.didDisappear() }
            harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
            harness.sut.reviseGoal("My goal", runID: "run", expectedRevision: 3)
            // when
            if reopen {
                harness.sut.cancelGoalDraft()
                harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
            } else {
                harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(id: "other"))
            }
            await waitUntil { !harness.sut.isBusy }
            // then
            #expect(harness.sut.goalRevisionError == nil)
            #expect(harness.sut.errorText == nil)
        }
    }

    @Test func givenSaveFailsWithNoDraft_whenSaving_thenMessageFallsBackToTheScreenError() async {
        // given
        let harness = makeVM(failure: ToolError.refused(code: "stale", message: "Revision is stale."))
        defer { harness.sut.didDisappear() }
        // when
        harness.sut.reviseGoal("My goal", runID: "run", expectedRevision: 3)
        await waitUntil { !harness.sut.isBusy && harness.sut.errorText != nil }
        // then
        #expect(harness.sut.errorText == "Revision is stale.")
        #expect(harness.sut.goalRevisionError == nil)
    }

    @Test func givenRun_whenProjectionHasNotArrived_thenNoGoalBlockContentExists() async {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        let run = WorkflowRunModel(raw: runRaw())
        // then: the projection is built off-main after the run is set, so none exists for another run's content
        #expect(harness.sut.goalPresentation(for: WorkflowRunModel(raw: runRaw(id: "elsewhere"))) == nil)
        // when
        await waitUntil { harness.sut.goalPresentation(for: run) != nil }
        // then
        #expect(harness.sut.goalPresentation(for: run)?.goalRevision == 3)
    }

    @Test func givenOpenDraft_whenRunShowsTheSavedRevisionWithSameText_thenDraftCloses() {
        // given
        let harness = makeVM()
        defer { harness.sut.didDisappear() }
        harness.sut.beginGoalDraft(run: WorkflowRunModel(raw: runRaw()))
        harness.sut.updateGoalDraft("Revised")
        // when
        harness.sut.selectedRun = WorkflowRunModel(raw: runRaw(revision: 4, goal: "Revised"))
        // then
        #expect(harness.sut.goalDraft == nil)
    }
}
