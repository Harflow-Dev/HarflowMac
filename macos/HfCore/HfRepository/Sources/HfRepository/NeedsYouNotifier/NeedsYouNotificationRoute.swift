import Foundation

// MARK: - NeedsYouNotificationRoute

/// Where a notification click leads, decided from the banner's `userInfo` and the current Needs you snapshot.
/// The app maps it to its own destination type and validates the identifiers it opens.
public enum NeedsYouNotificationRoute: Equatable, Sendable {
    case task(String)
    /// An item, or the list when the request is no longer in the snapshot.
    case needsYou(itemID: String?)
    case workflowRun(String)

    /// Banners delivered before the typed keys existed carry only `task_id`, `workflow_run_id` or `needs_you_item`; they keep their targets.
    public static func destination(userInfo: [AnyHashable: Any], snapshot: NeedsYouSnapshot) -> NeedsYouNotificationRoute? {
        let text = { (key: String) in userInfo[key] as? String }
        if let kind = text("needs_you_kind") {
            return .needsYou(itemID: item(kind: kind, run: text("workflow_run_id"), task: text("task_id"),
                                          interaction: text("interaction_id"), in: snapshot)?.id)
        }
        if let task = text("task_id") { return .task(task) }
        if let run = text("workflow_run_id") { return .workflowRun(run) }
        if let item = text("needs_you_item") { return .needsYou(itemID: item) }
        return nil
    }

    // A question or approval needs its `interaction_id` to match; without one it opens the list. A recovery's engine key is a point key, not the checkpoint id,
    // so recoveries resolve by root run alone.
    private static func item(kind: String, run: String?, task: String?, interaction: String?, in snapshot: NeedsYouSnapshot) -> NeedsYouItem? {
        snapshot.items.first { item in
            switch kind {
            case "question":
                item.kind == .question && item.rootRunID == run && interaction != nil && item.decisionID == interaction
            case "approval":
                item.kind == .approval && item.taskID == task && interaction != nil && item.approval?.id == interaction
            case "recovery":
                item.kind == .recovery && item.rootRunID == run
            default:
                false
            }
        }
    }
}
