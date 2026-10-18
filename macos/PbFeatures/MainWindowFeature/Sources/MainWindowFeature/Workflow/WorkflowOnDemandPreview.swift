#if DEBUG
import MonitorCore
import PbUI
import SwiftUI

// MARK: - WorkflowOnDemandPreview

@MainActor
enum WorkflowOnDemandPreview {
    static var node: WorkflowNodeModel {
        WorkflowNodeModel(raw: [
            "id": .string("research"), "title": .string("API researcher"),
            "instructions": .string("Research the assigned API and return evidence."),
            "call_condition": .string("Call when API behavior needs verification."),
            "agent": .object(["backend": .string("codex"), "fallbacks": .array([])]),
            "freedom": .string("read_only"), "network": .bool(true), "effective_network": .bool(true),
            "session_mode": .string("agent_decides"), "execution_mode": .string("headless")
        ])
    }

    static func calls(status: String = "running") -> [WorkflowOnDemandCall] {
        [call(number: 1, status: "succeeded", kind: "routing"), call(number: 2, status: status, kind: "node_question")]
    }

    static func call(number: Int, status: String, kind: String) -> WorkflowOnDemandCall {
        var raw: [String: JSONValue] = [
            "id": .string("call-\(number)"), "node_id": .string("preview-run:research"), "call_number": .number(Double(number)),
            "assignment": .string(number == 1 ? "Identify the API endpoints used by the client." :
            "Confirm the refresh endpoint's error response."),
            "reason": .string("Implementation depends on the response contract."),
            "origin": .object([
                "kind": .string(kind),
                "title": .string("Implementation"),
                "node_id": .string("implementation"),
                "workflow_run_id": .string("preview-run")
            ]),
            "status": .string(status), "started_at": .number(Date.now.timeIntervalSince1970 - 72), "task_id": .string("preview-task")
        ]
        if status != "running" {
            raw["finished_at"] = .number(Date.now.timeIntervalSince1970 - 10)
            raw["result"] = .object([
                "status": .string(status),
                "result": .object(["summary": .string("Verified the API contract against its documented response.")]),
                "evidence": .array([.string("Observed fixture response")])
            ])
            if status == "failed" { raw["failure"] = .string("The API request failed.") }
        }
        return WorkflowOnDemandCall(raw: raw)
    }

    static func make(run: Bool = false, orchestrator: Bool = false, status: String = "running") -> WorkflowVM {
        let vm = WorkflowPreview.make(run: run)
        vm.definition["on_demand_nodes"] = .array([.object(node.raw)])
        if run {
            var raw = vm.selectedRun?.raw ?? [:]
            raw["status"] = .string("running")
            raw.removeValue(forKey: "attention_reason")
            var catalog = node.raw
            catalog["node_id"] = .string("preview-run:research")
            catalog["local_node_id"] = .string("research")
            catalog["source_workflow_run_id"] = .string("preview-run")
            catalog["call_count"] = .number(2)
            catalog["active_call_id"] = status == "running" ? .string("call-2") : .null
            raw["on_demand_nodes"] = .array([.object(catalog)])
            raw["on_demand_calls"] = .array(calls(status: status).map { .object($0.raw) })
            raw["on_demand_state"] = .object([
                "kind": .string(status == "running" ? "waiting" : "deciding"),
                "title": .string("API researcher")
            ])
            raw["definition"] = .object(vm.definition)
            vm.selectedRun = WorkflowRunModel(raw: raw)
        }
        WorkflowPreview.synchronizeRun(vm)
        vm.selectStandalone(orchestrator ? WorkflowStandalone.orchestratorID : run ? "preview-run:research" : "research")
        return vm
    }
}

#Preview("On-demand editor light") { WorkflowView(WorkflowOnDemandPreview.make())
.frame(
    width: PbRadius.Metrics.workflowPreviewWidth,
    height: PbRadius.Metrics.workflowPreviewHeight
)
.preferredColorScheme(.light)
}

#Preview("On-demand editor dark") { WorkflowView(WorkflowOnDemandPreview.make())
.frame(
    width: PbRadius.Metrics.workflowPreviewWidth,
    height: PbRadius.Metrics.workflowPreviewHeight
)
.preferredColorScheme(.dark)
}

#Preview("On-demand run light") { WorkflowView(WorkflowOnDemandPreview.make(run: true))
.frame(
    width: PbRadius.Metrics.workflowPreviewWidth,
    height: PbRadius.Metrics.workflowPreviewHeight
)
.preferredColorScheme(.light)
}

#Preview("On-demand run dark") { WorkflowView(WorkflowOnDemandPreview.make(run: true))
.frame(
    width: PbRadius.Metrics.workflowPreviewWidth,
    height: PbRadius.Metrics.workflowPreviewHeight
)
.preferredColorScheme(.dark)
}

#Preview("On-demand inspector light") {
    WorkflowInspector(viewModel: WorkflowOnDemandPreview.make())
.frame(width: PbRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.light)
}

#Preview("On-demand inspector dark") {
    WorkflowInspector(viewModel: WorkflowOnDemandPreview.make())
.frame(width: PbRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.dark)
}

#Preview("Orchestrator inspector light") {
    WorkflowInspector(viewModel: WorkflowOnDemandPreview.make(orchestrator: true))
.frame(width: PbRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.light)
}

#Preview("Orchestrator inspector dark") {
    WorkflowInspector(viewModel: WorkflowOnDemandPreview.make(orchestrator: true))
.frame(width: PbRadius.Metrics.formPreviewWidth)
    .preferredColorScheme(.dark)
}

#Preview("Standalone running light") {
    WorkflowStandaloneBar(viewModel: WorkflowOnDemandPreview.make(run: true)).preferredColorScheme(.light)
}

#Preview("Standalone settled dark") {
    WorkflowStandaloneBar(viewModel: WorkflowOnDemandPreview.make(run: true, status: "succeeded")).preferredColorScheme(.dark)
}

#Preview("Call list running light") { WorkflowOnDemandCallsView(
    node: WorkflowOnDemandPreview.node,
    calls: WorkflowOnDemandPreview.calls(),
    onOpenTask: { _ in }
).preferredColorScheme(.light) }
#Preview("Call list failed dark") { WorkflowOnDemandCallsView(
    node: WorkflowOnDemandPreview.node,
    calls: WorkflowOnDemandPreview.calls(status: "failed"),
    onOpenTask: { _ in }
).preferredColorScheme(.dark) }
#Preview("Call badge light") {
    WorkflowOnDemandCallBadge(call: WorkflowOnDemandPreview.call(number: 1, status: "succeeded", kind: "routing"))
    .preferredColorScheme(.light)
}

#Preview("Call badge dark") {
    WorkflowOnDemandCallBadge(call: WorkflowOnDemandPreview.call(number: 1, status: "running", kind: "routing"))
    .preferredColorScheme(.dark)
}
#endif
