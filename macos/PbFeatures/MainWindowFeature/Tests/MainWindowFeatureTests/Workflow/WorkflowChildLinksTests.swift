@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowChildLinksTests

struct WorkflowChildLinksTests {
    @Test func givenRepeatedAndDistinctWorkflows_whenBuildingLinks_thenIdentityAndExactRunsArePreserved() {
        // given
        func activation(_ child: String, workflow: String, status: String) -> JSONValue {
            .object(["invocation": .object(["child_workflow_run_id": .string(child), "workflow_id": .string(workflow),
                                          "workflow_name": .string("Review"), "stage": .string("running")]),
                     "node_result": .object(["result": .object(["child_outcome": .object(["child_status": .string(status)])])])])
        }
        let run = WorkflowRunModel(raw: ["activations": .array([
            activation("first", workflow: "review", status: "completed"),
            activation("second", workflow: "review", status: "cancelled"),
            activation("other", workflow: "another", status: "failed"),
            activation("first", workflow: "review", status: "completed")
        ])])
        // when
        let groups = WorkflowChildLinkGroup.build(run: run)
        // then
        #expect(groups.count == 2)
        #expect(groups[0].runs.map(\.id) == ["first", "second"])
        #expect(groups[0].runs.map(\.ordinal) == [1, 2])
        #expect(groups[0].runs.map(\.status) == ["completed", "cancelled"])
        #expect(groups[1].runs.map(\.id) == ["other"])
    }

    @Test func givenMissingWorkflowIdentityAndEmptyTargets_whenBuildingLinks_thenNoUnrelatedRunsAreMerged() {
        // given
        let run = WorkflowRunModel(raw: ["activations": .array(["one", "two", ""].map { child in
            .object(["invocation": .object(["child_workflow_run_id": .string(child), "workflow_name": .string("Same name")])])
        })])
        // when
        let groups = WorkflowChildLinkGroup.build(run: run)
        // then
        #expect(groups.map(\.id) == ["run:one", "run:two"])
        #expect(groups.allSatisfy { $0.runs.count == 1 && $0.runs[0].status == "unknown" })
    }
}
