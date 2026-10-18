import Foundation
import MonitorCore
import PbUI

// MARK: - WorkflowExecutionPresentation

/// Projects execution identity without treating native children as process-backed tasks.
struct WorkflowExecutionPresentation: Equatable {
    let raw: [String: JSONValue]
    var isSubagent: Bool { raw["execution_kind"]?.stringValue == "native_subagent" }
    var label: String { isSubagent ? "Subagent" : "Headless" }
    var fallbackReason: String? { raw["execution_fallback_reason"]?.stringValue }
    var ownerTaskID: String? { raw["owner_task_id"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    var activityLimited: Bool { isSubagent && raw["activity_level"]?.stringValue != "full" }
    var canTakeover: Bool { false }
    var canCancel: Bool { isSubagent && raw["can_cancel_child"]?.boolValue == true }
    var canResume: Bool { isSubagent && raw["can_resume_child"]?.boolValue == true }

    /// True only while existing activations prove no worker step has started (SPEC §6.4): an
    /// activation with `role == "node"` suppresses the prestart placeholder even when its
    /// columns or tasks are empty — activations carry `created_at`/`status`/`role`, not a
    /// `started_at`, so a worker step's presence, not visible activity, is the proof. An
    /// orchestrator-only decision is control activity, not a worker step. This is a
    /// presentation input, never an execution claim: reserved or uncertain activity is not
    /// relabelled by it.
    static func showsPrestartPlaceholder(activations: [[String: JSONValue]]) -> Bool {
        !activations.contains { $0["role"]?.stringValue == "node" }
    }
}

// MARK: - WorkflowRunStatusBadge

/// The workflow run header's pure status → shared badge mapping (SPEC §5.1/§6.4). It maps
/// presentation only: the raw status, the settling flag and every eligibility stay exactly as
/// polybridge reported them. `needs_input` and `needs_attention` share the SPEC's one
/// "Needs attention" family shape and word; an unmapped status keeps its readable raw label
/// on the neutral dashed-circle treatment — a visual mapping never claims an execution state.
enum WorkflowRunStatusBadge {
    static func presentation(status: String, isSettling: Bool) -> StatusBadgePresentation {
        if isSettling {
            return StatusBadgePresentation(indicator: .spinner, label: "Settling", tint: .running)
        }
        switch status.lowercased().replacingOccurrences(of: "_", with: " ") {
        case "starting":
            return StatusBadgePresentation(indicator: .spinner, label: "Starting", tint: .running)
        case "running":
            return StatusBadgePresentation(indicator: .spinner, label: "Running", tint: .running)
        case "paused":
            return StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Paused", tint: .warning)
        case "cancelling":
            // The shared stop shape and neutral fill, never relabelled as Pending.
            return StatusBadgePresentation(indicator: .symbol("stop.fill"), label: "Cancelling…", tint: .pending)
        case "needs attention", "needs input":
            return StatusBadgePresentation(indicator: .symbol("exclamationmark.triangle.fill"), label: "Needs attention", tint: .warning)
        case "completed":
            return StatusBadge.presentation(for: .completed)
        case "failed":
            return StatusBadge.presentation(for: .failed)
        case "cancelled":
            return StatusBadge.presentation(for: .cancelled)
        default:
            return StatusBadgePresentation(
                indicator: .symbol("circle.dashed"),
                label: status.replacingOccurrences(of: "_", with: " ").prefix(1).uppercased()
                    + status.replacingOccurrences(of: "_", with: " ").dropFirst(),
                tint: .unknown
            )
        }
    }
}

// MARK: - WorkflowNodeStatusPresentation

/// Nodes retain raw state distinctions while sharing the badge's word, shape and tint families.
enum WorkflowNodeStatusPresentation {
    static func presentation(status: String) -> StatusBadgePresentation {
        if status == "pending" { return StatusBadge.presentation(for: .other("pending")) }
        return WorkflowRunStatusBadge.presentation(status: status, isSettling: false)
    }
}

// MARK: - WorkflowRunMetadata

/// The run-header state line's honest projection (SPEC §6.4): only the fields the run record
/// already reports. No ordinal "step N of M" is derived — none exists reliably — and no
/// elapsed value is invented here.
enum WorkflowRunMetadata {
    static func startedAt(_ run: WorkflowRunModel) -> Date? {
        guard let seconds = run.raw["created_at"]?.doubleValue, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    static func repoName(_ run: WorkflowRunModel) -> String? {
        guard let path = run.raw["repo_path"]?.stringValue, !path.isEmpty else { return nil }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
