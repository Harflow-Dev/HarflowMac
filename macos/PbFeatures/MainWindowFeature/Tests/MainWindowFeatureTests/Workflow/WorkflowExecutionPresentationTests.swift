import Foundation
@testable import MainWindowFeature
import MonitorCore
import PbUI
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

    // MARK: run status badge mapping

    @Test func givenEachWorkflowRunStatus_whenBadged_thenLabelTintAndShapeAreHonest() {
        // given / when / then — the tested pure mapping (SPEC §5.1/§6.4); the raw status is
        // never reinterpreted into a state polybridge did not report.
        #expect(WorkflowRunStatusBadge.presentation(status: "starting", isSettling: false)
                == StatusBadgePresentation(indicator: .spinner, label: "Starting", tint: .running))
        #expect(WorkflowRunStatusBadge.presentation(status: "running", isSettling: false)
                == StatusBadgePresentation(indicator: .spinner, label: "Running", tint: .running))
        #expect(WorkflowRunStatusBadge.presentation(status: "paused", isSettling: false)
                == StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Paused", tint: .warning))
        #expect(WorkflowRunStatusBadge.presentation(status: "cancelling", isSettling: false)
                == StatusBadgePresentation(indicator: .symbol("stop.fill"), label: "Cancelling…", tint: .pending))
        for status in ["needs_attention", "needs_input", "Needs Input"] {
            #expect(WorkflowRunStatusBadge.presentation(status: status, isSettling: false)
                    == StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Needs attention", tint: .warning), "\(status)")
        }
    }

    @Test func givenSettlingFlag_whenBadged_thenItWinsOverEveryRawStatus() {
        // given / when / then — settling is the one override; the raw status stays untouched.
        for status in ["starting", "running", "needs_attention", "failed", "completed", "mystery"] {
            let badge = WorkflowRunStatusBadge.presentation(status: status, isSettling: true)
            #expect(badge == StatusBadgePresentation(indicator: .spinner, label: "Settling", tint: .running), "\(status)")
        }
    }

    @Test func givenTerminalWorkflowStatuses_whenBadged_thenSharedBadgeCompositionsAreReused() {
        // given / when / then — completed/failed/cancelled reuse the shared TaskStatus mapping,
        // so the workflow badge never invents its own terminal shape or word.
        #expect(WorkflowRunStatusBadge.presentation(status: "completed", isSettling: false) == StatusBadge.presentation(for: .completed))
        #expect(WorkflowRunStatusBadge.presentation(status: "failed", isSettling: false) == StatusBadge.presentation(for: .failed))
        #expect(WorkflowRunStatusBadge.presentation(status: "cancelled", isSettling: false) == StatusBadge.presentation(for: .cancelled))
    }

    @Test func givenUnknownWorkflowStatus_whenBadged_thenReadableRawLabelOnNeutralDashedCircle() {
        // given / when
        let badge = WorkflowRunStatusBadge.presentation(status: "waiting_for_owner", isSettling: false)
        // then — the existing readable sentence-case label, no false execution claim.
        #expect(badge.label == "Waiting for owner")
        #expect(badge.indicator == .symbol("circle.dashed"))
        #expect(badge.tint == .unknown)
    }

    @Test func givenNodeStates_whenPresented_thenFailedAndUncertainKeepTheirHonestSharedFamilies() {
        // given / when
        let failed = WorkflowNodeStatusPresentation.presentation(status: "failed")
        let uncertain = WorkflowNodeStatusPresentation.presentation(status: "uncertain")
        let completed = WorkflowNodeStatusPresentation.presentation(status: "completed")
        let pending = WorkflowNodeStatusPresentation.presentation(status: "pending")
        // then
        #expect(failed == StatusBadge.presentation(for: .failed))
        #expect(uncertain == StatusBadgePresentation(indicator: .symbol("circle.dashed"), label: "Uncertain", tint: .unknown))
        #expect(completed == StatusBadge.presentation(for: .completed))
        #expect(pending == StatusBadge.presentation(for: .other("pending")))
        #expect(WorkflowNodeStatusPresentation.presentation(status: "not_selected").label == "Not selected")
        #expect(WorkflowNodeStatusPresentation.presentation(status: "needs_attention")
            == StatusBadge.presentation(for: .other("needs_attention")))
    }

    // MARK: proven-prestart placeholder

    @Test func givenNoWorkerActivation_whenPrestartChecked_thenPlaceholderIsProven() {
        // given / when / then — no activations at all, or orchestrator-only control activity
        // (a decision is not a worker step), keep the prestart placeholder honest.
        #expect(WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: []))
        #expect(WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: [
            ["role": .string("orchestrator"), "status": .string("running"), "created_at": .number(1)]
        ]))
    }

    @Test func givenNodeRoleActivation_whenPrestartChecked_thenPlaceholderIsSuppressedEvenWithEmptyColumns() {
        // given — a backend activation carries role/status/tasks/created_at, not a started_at;
        // its presence, not its visible activity, is the proof a step started.
        let activation: [String: JSONValue] = ["role": .string("node"), "status": .string("running"), "created_at": .number(1)]
        // when / then
        #expect(!WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: [activation]))
        #expect(!WorkflowExecutionPresentation.showsPrestartPlaceholder(activations: [
            activation, ["role": .string("orchestrator"), "status": .string("completed")]
        ]))
    }

    // MARK: run header metadata

    @Test func givenRunMetadata_whenProjected_thenOnlyReportedFieldsAppear() {
        // given
        let run = WorkflowRunModel(raw: ["created_at": .number(1_700_000_000), "repo_path": .string("/tmp/OrbitDesk")])
        let empty = WorkflowRunModel(raw: [:])
        let invalid = WorkflowRunModel(raw: ["created_at": .number(0), "repo_path": .string("")])
        // when / then
        #expect(WorkflowRunMetadata.startedAt(run) == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(WorkflowRunMetadata.repoName(run) == "OrbitDesk")
        #expect(WorkflowRunMetadata.startedAt(empty) == nil)
        #expect(WorkflowRunMetadata.repoName(empty) == nil)
        #expect(WorkflowRunMetadata.startedAt(invalid) == nil)
        #expect(WorkflowRunMetadata.repoName(invalid) == nil)
    }
}
