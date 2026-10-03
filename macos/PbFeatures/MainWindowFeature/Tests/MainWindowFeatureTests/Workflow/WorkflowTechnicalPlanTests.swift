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

}
