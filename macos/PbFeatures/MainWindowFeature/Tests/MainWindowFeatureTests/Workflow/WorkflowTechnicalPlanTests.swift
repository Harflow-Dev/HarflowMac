@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowTechnicalPlanTests

struct WorkflowTechnicalPlanTests {
    func run(plans: [String], status: String = "completed") -> WorkflowRunModel {
        let definition: [String: JSONValue] = ["nodes": .array([.object(["id": .string("plan"), "role": .string("planning")])])]
        let activations = plans.map { text -> JSONValue in
            .object(["node_id": .string("plan"), "role": .string("node"), "status": .string(status),
                     "node_result": .object(["status": .string("succeeded"), "result": .object(["technical_plan": .string(text)])])])
        }
        return WorkflowRunModel(raw: ["definition": .object(definition), "activations": .array(activations)])
    }

    @Test func givenReplanning_whenTechnicalPlanRead_thenLatestSettledSuccessfulPlanWins() {
        // given
        let first = run(plans: ["Original approach"])
        let replanned = run(plans: ["Original approach", "Updated approach"])
        // when / then
        #expect(first.technicalPlan == "Original approach")
        #expect(replanned.technicalPlan == "Updated approach")
        #expect(run(plans: ["Unfinished approach"], status: "running").technicalPlan == nil)
        #expect(run(plans: []).technicalPlan == nil)
    }

    @Test func givenCanonicalPlan_whenReplanned_thenRunFieldAndSourceIdentifyCurrentPlan() {
        // given
        var current = run(plans: ["Historical approach"])
        current.raw["technical_plan"] = .string("Current approach")
        current.raw["technical_plan_execution_id"] = .string("planning-2")
        // when / then
        #expect(current.technicalPlan == "Current approach")
        #expect(current.raw["technical_plan_execution_id"]?.stringValue == "planning-2")
        #expect(run(plans: ["Another run"]).technicalPlan == "Another run")
    }

    @Test func givenNoChecklistProposal_whenOrchestratorHasNotAccepted_thenShowsProposalAndReasonEvenAfterFailure() {
        // given
        var proposed = noChecklistRun(status: "failed")
        // when / then
        #expect(proposed.emptyChecklistPresentation.title == "No checklist proposed")
        #expect(proposed.emptyChecklistPresentation.reason == "Review only; no implementation tasks")
        proposed.raw["status"] = .string("running")
        #expect(proposed.emptyChecklistPresentation.title == "No checklist proposed")
    }

    @Test func givenAcceptedNoChecklist_whenRenderingPlan_thenShowsJudgmentAndKeepsTechnicalPlan() {
        // given
        var accepted = noChecklistRun(status: "running")
        accepted.raw["checklist_disposition"] = .object([
            "status": .string("not_needed"), "execution_id": .string("planning-1"),
            "reason": .string("Review only; no implementation tasks")
        ])
        // when / then
        #expect(accepted.emptyChecklistPresentation.title == "No checklist needed")
        #expect(accepted.technicalPlan == "Inspect the patch")
        // A newer proposal must still be judged; prior acceptance cannot accept it implicitly.
        var next = accepted.activations[0]
        next["id"] = .string("planning-2")
        accepted.raw["activations"] = .array([.object(next)])
        #expect(accepted.emptyChecklistPresentation.title == "No checklist proposed")
    }

    private func noChecklistRun(status: String) -> WorkflowRunModel {
        // given
        var value = run(plans: [])
        value.raw["status"] = .string(status)
        value.raw["activations"] = .array([.object([
            "id": .string("planning-1"), "node_id": .string("plan"), "role": .string("node"), "status": .string("completed"),
            "node_result": .object(["status": .string("succeeded"), "result": .object([
                "no_checklist_needed": .bool(true), "checklist_reason": .string("Review only; no implementation tasks"),
                "technical_plan": .string("Inspect the patch")
            ])])
        ])])
        return value
    }

}
