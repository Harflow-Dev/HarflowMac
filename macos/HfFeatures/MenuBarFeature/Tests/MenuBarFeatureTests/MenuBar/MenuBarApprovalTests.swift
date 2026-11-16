import Foundation
import HfRepository
@testable import MenuBarFeature
import MonitorCore
import Testing

// MARK: - MenuBarApprovalTests

@Suite struct MenuBarApprovalTests {
    @Test func givenCallerResponseCapabilityMissing_whenSectionBuilds_thenApprovalCardHasNoDecisions() {
        // given
        var item = approvalItem()
        item.approvalCanRespond = false
        // when
        let section = MenuBarNeedsYouSection(NeedsYouSnapshot(phase: .ready, items: [item]))
        // then
        #expect(section?.rows.first?.canDecide == false)
        #expect(section?.rows.first?.item == item)
        #expect(section?.count == 1)
    }

    @Test(arguments: ["approve", "reject"])
    func givenOtherChannelWins_whenMenuResultMaps_thenDecisionChannelAndTimeRemain(decision: String) {
        // given
        let error = ToolError.structuredRefusal(code: "approval_error", message: "Already answered", data: [
            "reason": .string("already_answered"), "interaction": .object([
                "interaction_id": .string("r1"), "task_id": .string("t1"), "action": .string("approval"),
                "answer": .string(decision), "answered_by": .string("caller"), "answered_at": .number(123)
            ])
        ])
        // when
        let lines = MenuBarApprovalResult.lines(.refused(error, current: nil))
        // then
        #expect(lines.first == "Already answered by the caller")
        #expect(lines.contains("Recorded decision: " + decision))
        #expect(lines.count == 3)
    }

    @Test func givenStaleResponse_whenMenuResultMaps_thenReadOnlyRefreshCopyIsExact() {
        // given
        let error = ToolError.structuredRefusal(code: "approval_error", message: "stale", data: ["reason": .string("not_current")])
        // when
        let lines = MenuBarApprovalResult.lines(.refused(error, current: nil))
        // then
        #expect(lines == ["The request changed or is no longer current. This response did not change it. Refresh to review the current action."])
        #expect(MenuBarApprovalResult.lines(.uncertain) == ["Delivery is unknown. The decision will not be retried."])
    }

    private func approvalItem() -> NeedsYouItem {
        NeedsYouItem(id: "approval:t1:r1", kind: .approval, runTitle: "Task", text: "Bash: git status",
                     ownership: .init(owner: "caller", callerEnded: false, engineNote: "", handover: nil), startedBy: "Original caller")
    }
}
