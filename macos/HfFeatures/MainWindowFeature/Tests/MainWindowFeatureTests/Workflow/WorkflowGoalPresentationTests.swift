import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowGoalPresentationTests

@Suite struct WorkflowGoalPresentationTests {
    private func run(revision: Int? = nil, status: String = "running", assessment: String? = nil,
                     history: [(Int, String)] = [], extra: [String: JSONValue] = [:]) -> WorkflowRunModel {
        var raw: [String: JSONValue] = ["workflow_run_id": .string("run"), "status": .string(status), "goal": .string("Ship it.")]
        if let revision { raw["goal_revision"] = .number(Double(revision)) }
        if let assessment { raw["goal_assessment"] = .object(["status": .string(assessment), "reason": .string("Because."),
                                                              "evidence_refs": .array([.string("ref-1")])]) }
        raw["goal_history"] = .array(history.map { .object(["revision": .number(Double($0.0)), "goal": .string($0.1)]) })
        return WorkflowRunModel(raw: raw.merging(extra) { _, new in new })
    }

    @Test(arguments: [(0, "GOAL"), (1, "GOAL"), (2, "Goal · revision 2"), (7, "Goal · revision 7")])
    func givenRevision_whenBuildingLabel_thenOnlyRevisedGoalsShowTheNumber(revision: Int, label: String) {
        // given / when
        let model = WorkflowGoalPresentation(run: run(revision: revision))
        // then
        #expect(model.label == label)
        #expect(model.formLabel == "Goal · revision \(max(1, revision))")
    }

    @Test(arguments: [
        ("running", nil, "Assessment: in progress"), ("starting", nil, "Assessment: in progress"),
        ("paused", nil, "Assessment: not met yet"), ("needs_input", nil, "Assessment: not met yet"),
        ("needs_attention", nil, "Assessment: not met yet"),
        ("completed", nil, nil), ("failed", nil, nil), ("pending", nil, nil),
        ("running", "unmet", "Assessment: not met yet"), ("paused", "unmet", "Assessment: not met yet"),
        ("completed", "unmet", "Assessment: not met"), ("failed", "unmet", "Assessment: not met"),
        ("running", "satisfied", "Assessment: met"), ("completed", "satisfied", "Assessment: met"),
        ("completed", "unverifiable", "Assessment: unverifiable"), ("running", "unverifiable", "Assessment: unverifiable"),
        ("completed", "odd", "Assessment: unverifiable")
    ] as [(String, String?, String?)])
    func givenRunStatusAndAssessment_whenBuildingRow_thenCopyFollowsTheMapping(status: String, assessment: String?, expected: String?) {
        // given / when
        let model = WorkflowGoalPresentation(run: run(revision: 1, status: status, assessment: assessment))
        // then
        #expect(model.assessmentText == expected)
    }

    @Test func givenAssessmentDetail_whenBuildingPresentation_thenReasonAndEvidenceAreKept() {
        // given / when
        let model = WorkflowGoalPresentation(run: run(revision: 1, status: "completed", assessment: "unmet"))
        // then
        #expect(model.assessmentReason == "Because.")
        #expect(model.evidenceRefs == ["ref-1"])
    }

    @Test func givenEngineShapedRunAtFirstRevision_whenBuildingHistory_thenCurrentRevisionIsNotListed() {
        // given: the engine seeds the history with revision 1 at creation
        let model = WorkflowGoalPresentation(run: run(revision: 1, history: [(1, "Ship it.")]))
        // then
        #expect(model.label == "GOAL")
        #expect(model.history.isEmpty)
    }

    @Test func givenRevisionThree_whenBuildingHistory_thenEarlierRevisionsAreNewestFirst() {
        // given / when
        let model = WorkflowGoalPresentation(run: run(revision: 3, history: [(1, "One"), (2, "Two"), (3, "Three")]))
        // then
        #expect(model.history.map(\.revision) == [2, 1])
        #expect(model.history.map(\.text) == ["Two", "One"])
    }

    @Test func givenMonitorAndEngineReasons_whenRevisionIsUnavailable_thenMonitorReasonWins() {
        // given
        let controls: JSONValue = .object(["revise_goal": .object(["allowed": .bool(false), "reason": .string("Monitor reason.")])])
        let both = run(revision: 2, extra: ["goal_revision_reason": .string("Engine reason."), "monitor_controls": controls])
        let engineOnly = run(revision: 2, extra: ["goal_revision_reason": .string("Engine reason.")])
        // when / then
        #expect(WorkflowGoalPresentation(run: both).unavailableReason == "Monitor reason.")
        #expect(WorkflowGoalPresentation(run: engineOnly).unavailableReason == "Engine reason.")
    }

    @Test func givenLostRace_whenRunRevisionAdvances_thenTheCardShowsOnlyAtExpectedPlusOne() {
        // given / when / then
        #expect(WorkflowGoalPresentation.showsAnsweredElsewhere(outcomeAction: "revise_goal", expectedRevision: 2, runRevision: 3))
        #expect(!WorkflowGoalPresentation.showsAnsweredElsewhere(outcomeAction: "revise_goal", expectedRevision: 2, runRevision: 4))
        #expect(!WorkflowGoalPresentation.showsAnsweredElsewhere(outcomeAction: "revise_goal", expectedRevision: 2, runRevision: 2))
        #expect(!WorkflowGoalPresentation.showsAnsweredElsewhere(outcomeAction: "resume", expectedRevision: 2, runRevision: 3))
        #expect(!WorkflowGoalPresentation.showsAnsweredElsewhere(outcomeAction: "revise_goal", expectedRevision: nil, runRevision: 3))
    }

    @Test(arguments: [
        (true, true, false, true), (true, false, true, true), (true, false, false, false),
        (false, true, true, false)
    ] as [(Bool, Bool, Bool, Bool)])
    func givenCardAndBlockVisibility_whenDecidingHeaderCopy_thenOnlyAShownCardInAMountedBlockSuppressesIt(
        cardShown: Bool, defaultShown: Bool, paneShowsGoal: Bool, suppressed: Bool) {
        // given / when
        let result = WorkflowGoalPresentation.suppressesHeaderOutcome(
            cardShown: cardShown, isDefaultSidebarShown: defaultShown, selectedPaneShowsGoal: paneShowsGoal)
        // then
        #expect(result == suppressed)
    }

    @Test func givenRuns_whenDecidingBlock_thenGoalOrRevisabilityShowsIt() {
        // given / when / then
        #expect(WorkflowGoalPresentation.showsBlock(run: run(revision: 1)))
        #expect(!WorkflowGoalPresentation.showsBlock(run: WorkflowRunModel(raw: ["workflow_run_id": .string("run")])))
        #expect(WorkflowGoalPresentation(run: run(revision: 1)).runID == "run")
    }
}
