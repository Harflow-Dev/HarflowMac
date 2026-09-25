import MonitorCore

/// Plain sentences for what polybridge reports as enforced. Each boolean in `enforcement` is a
/// strict claim, so a line is shown only when the claim is True — never inferred from `freedom`.
///
/// Moved out of the app target's `InspectorView.swift` (Phase 2 package skeleton); behaviour is
/// unchanged.
public enum EnforcementText {
    public static func lines(_ enforcement: [String: JSONValue]?) -> [String] {
        guard let enforcement else { return [] }
        var lines: [String] = []
        if enforcement["os_enforced"]?.boolValue == true { lines.append("Restrictions enforced by the OS sandbox") }
        if enforcement["writes_confined"]?.boolValue == true { lines.append("File writes confined to the workspace (+ temp dirs)") }
        if enforcement["commit_push_blocked"]?.boolValue == true {
            lines.append("Git commit and push blocked")
        } else if enforcement["direct_commit_commands_denied"]?.boolValue == true {
            lines.append("Direct git commit/push commands denied (not a full block)")
        }
        if enforcement["publish_attempts_allowed_by_polybridge"]?.boolValue == true { lines.append("Allowed to attempt commit/push/PR") }
        if let network = enforcement["network_access"]?.stringValue { lines.append("Network: \(network.replacingOccurrences(of: "_", with: " "))") }
        return lines
    }
    
    /// The Parallel view footer: only what every member's enforcement actually says.
    public static func common(_ tasks: [TaskInfo]) -> String? {
        let sets = tasks.map { Set(lines($0.enforcement)) }
        guard let first = sets.first, sets.count == tasks.count, !tasks.isEmpty else { return nil }
        let shared = sets.dropFirst().reduce(first) { $0.intersection($1) }
        guard !shared.isEmpty else { return nil }
        return "Enforced for every agent here: " + shared.sorted().joined(separator: "; ") + "."
    }
}
