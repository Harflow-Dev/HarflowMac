@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowExecutionPresentationTests

struct WorkflowExecutionPresentationTests {
    @Test func givenNativeSchedulingPolicy_whenRunPresented_thenFrozenWorkerAndSharedControlLimitIsVisible() {
        // given
        let run = WorkflowRunModel(raw: ["scheduling_policy": .string("native_workers_plus_control_v1"),
            "definition": .object(["max_parallel": .number(1)])])
        // when / then
        #expect(run.schedulingPolicyDescription == "Up to 1 worker + one shared orchestrator turn")
        #expect(WorkflowRunModel(raw: [:]).schedulingPolicyDescription == nil)
    }

    @Test func givenHistoricalAttempt_whenPresented_thenHeadlessRemainsDefault() {
        // given
        let model = WorkflowExecutionPresentation(raw: [:])
        // when / then
        #expect(model.label == "Headless")
        #expect(!model.canCancel)
        #expect(!model.canResume)
    }

    @Test func givenNativeChild_whenPresented_thenTakeoverAbsentAndControlsFailClosed() {
        // given
        let model = WorkflowExecutionPresentation(raw: ["execution_kind": .string("native_subagent"), "owner_task_id": .string("parent")])
        // when / then
        #expect(model.label == "Subagent")
        #expect(model.ownerTaskID == "parent")
        #expect(model.activityLimited)
        #expect(!model.canTakeover)
        #expect(!model.canCancel)
        #expect(!model.canResume)
    }

    @Test func givenCertifiedControls_whenPresented_thenOnlyExplicitCapabilitiesAppear() {
        // given
        let model = WorkflowExecutionPresentation(raw: [
            "execution_kind": .string("native_subagent"), "activity_level": .string("full"), "can_cancel_child": .bool(true)
        ])
        // when / then
        #expect(model.canCancel)
        #expect(!model.canResume)
        #expect(!model.activityLimited)
    }

    @Test func givenSettledNativeTask_whenTerminalEligibilityChecked_thenStillRefused() {
        // given
        let task = TaskInfo(.object(["task_id": .string("child"), "execution_kind": .string("native_subagent"), "workflow_status": .string("completed")]))
        // when / then
        #expect(!WorkflowNodePresentation.allowsTerminal(task))
    }
}
