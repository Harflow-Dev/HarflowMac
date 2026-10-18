@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite
struct WorkflowCandidateSettingsTests {
    @Test
    func givenCallerApprovalOptIn_whenTurnCapIsMissingOrExplicit_thenOnlyExplicitCapIsShown() {
        let implicit: [String: JSONValue] = ["backend": .string("claude"), "caller_approvals": .bool(true)]
        #expect(WorkflowCandidateSettings.turnLimitText(implicit).isEmpty)
        #expect(implicit["max_turns"] == nil)

        let explicit: [String: JSONValue] = [
            "backend": .string("claude"), "caller_approvals": .bool(true), "max_turns": .number(100)
        ]
        #expect(WorkflowCandidateSettings.turnLimitText(explicit) == "100")

        let preserved = WorkflowCandidateSettings.replacingBackend(
            in: implicit, with: "vibe", supportsCallerApprovals: true)
        #expect(preserved["caller_approvals"] == .bool(true))
        #expect(preserved["max_turns"] == nil)

        let cleared = WorkflowCandidateSettings.replacingBackend(
            in: implicit, with: "codex", supportsCallerApprovals: false)
        #expect(cleared["caller_approvals"] == .bool(false))
    }
}
