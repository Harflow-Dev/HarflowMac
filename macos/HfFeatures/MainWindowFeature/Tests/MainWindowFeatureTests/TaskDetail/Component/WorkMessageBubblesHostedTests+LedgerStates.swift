import AppKit
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkMessageBubblesHostedTests ledger states

extension WorkMessageBubblesHostedTests {
    @Test(arguments: [false, true], ["queued", "delivering", "delivered", "cancelled", "future-status", "delivery_unknown"])
    func givenTaskOrWorkflowNodePhase_whenProductionTailHosted_thenExactCopyAndCancellationFollowLedger(
        workflowNode: Bool, status: String
    ) async {
        // given
        let text = "Message content for the ledger state"
        var record: [String: JSONValue] = ["id": .string("message"), "seq": .number(1),
                                           "status": .string(status), "text": .string(text)]
        if status == "delivery_unknown" { record["reason"] = .string("Engine delivery explanation") }
        var raw: [String: JSONValue] = ["messages": .array([.object(record)])]
        if workflowNode {
            raw["workflow_run_id"] = .string("run")
            raw["task_id"] = .string("node")
        }
        let phase = WorkMessageOutcome.ledger(raw)
        let tail = ActivityFeedTailPresentation.standard(.init(
            workMessages: WorkMessageBubble.project(raw: raw),
            liveStep: .init(text: "Live work", indicator: .singleDot),
            outcome: phase, outcomeUsesFocusTarget: true
        ))
        let fixture = RedesignHost(
            ActivityFeedNativeTailContent(presentation: tail, actions: ActivityFeedNativeActions(), style: .transcript)
                .frame(width: 600), size: CGSize(width: 600, height: 500)
        )
        defer { fixture.close() }
        let expectedOutcome = ["delivering": "Delivery is in progress.", "delivered": "Message delivered.",
                               "cancelled": "Queued message cancelled."][status]
        let metadataOnly = status == "delivered" || status == "cancelled"
        // when
        await fixture.settle {
            fixture.element("Live work") != nil
                && (metadataOnly || fixture.element(text) != nil)
                && (expectedOutcome.map { fixture.element($0) != nil } ?? true)
        }
        // then
        #expect(phase == expectedOutcome)
        #expect((fixture.element(text) == nil) == metadataOnly)
        #expect((fixture.element("Cancel queued message") != nil) == (status == "queued"))
        for line in ["Delivery is in progress.", "Message delivered.", "Queued message cancelled."] {
            #expect((fixture.element(line) != nil) == (line == expectedOutcome))
        }
        switch status {
        case "queued", "delivering":
            #expect(fixture.element("Queued") != nil)
        case "delivery_unknown" where !workflowNode:
            #expect(fixture.element("Delivery uncertain") != nil)
            #expect(fixture.element("Delivery could not be confirmed. The message is not requeued.\nEngine delivery explanation") != nil)
        case "future-status", "delivery_unknown":
            // Workflow ledgers have no standalone historical delivery_unknown interpretation.
            #expect(fixture.element("Delivery status unavailable") != nil)
        default:
            #expect(fixture.element("Queued") == nil)
        }
    }
}
