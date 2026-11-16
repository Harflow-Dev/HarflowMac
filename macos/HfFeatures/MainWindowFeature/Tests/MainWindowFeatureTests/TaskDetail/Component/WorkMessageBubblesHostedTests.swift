import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkMessageBubblesHostedTests

@MainActor @Suite(.serialized) struct WorkMessageBubblesHostedTests {
    private static let cancelLabel = "Cancel queued message"

    private func bubbles() -> [WorkMessageBubble] {
        [WorkMessageBubble(id: "m", seq: 1, kind: .queued(canCancel: true, note: nil), text: "Hold this thought")]
    }

    private func isEnabled(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
        return (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? false
    }

    @Test func givenNoCancelHandler_whenHosted_thenNoCancelControlIsShown() async {
        // given
        let fixture = RedesignHost(WorkMessageBubblesView(bubbles: bubbles()).frame(width: 420), size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Hold this thought") != nil }
        // then
        #expect(fixture.element("Hold this thought") != nil)
        #expect(fixture.element(Self.cancelLabel) == nil)
    }

    @Test func givenHandlerAndBusySurface_whenHosted_thenCancelIsShownDisabled() async throws {
        // given
        let fixture = RedesignHost(WorkMessageBubblesView(bubbles: bubbles(), onCancel: { _ in }, isCancelDisabled: true).frame(width: 420),
                                   size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element(Self.cancelLabel) != nil }
        // then
        let cancel = try #require(fixture.element(Self.cancelLabel))
        #expect(!isEnabled(cancel))
    }

    @Test func givenHandlerAndIdleSurface_whenCancelPressed_thenHandlerReceivesTheBubbleID() async throws {
        // given
        var cancelled: [String] = []
        let fixture = RedesignHost(WorkMessageBubblesView(bubbles: bubbles(), onCancel: { cancelled.append($0) }).frame(width: 420),
                                   size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        await fixture.settle { fixture.element(Self.cancelLabel) != nil }
        let cancel = try #require(fixture.element(Self.cancelLabel))
        // when
        #expect(isEnabled(cancel))
        #expect(fixture.press(cancel))
        // then
        await fixture.settle { !cancelled.isEmpty }
        #expect(cancelled == ["m"])
    }

    @Test func givenSettledBubble_whenHostedWithHandler_thenNoCancelControlIsShown() async {
        // given
        let settled = [WorkMessageBubble(id: "s", seq: 1, kind: .undeliverable("gone"), text: "Lost message")]
        let fixture = RedesignHost(WorkMessageBubblesView(bubbles: settled, onCancel: { _ in }).frame(width: 420),
                                   size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Lost message") != nil }
        // then
        #expect(fixture.element(Self.cancelLabel) == nil)
    }

    @Test(arguments: ["delivering", "future-status"])
    func givenReadOnlyMessageState_whenHosted_thenTextRemainsWithoutCancel(status: String) async {
        // given
        let values = WorkMessageBubble.project(items: [.init(id: "m", text: "Retained message", status: status, reason: nil)])
        let fixture = RedesignHost(WorkMessageBubblesView(bubbles: values, onCancel: { _ in }).frame(width: 420),
                                   size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Retained message") != nil }
        // then
        #expect(fixture.element("Retained message") != nil)
        #expect(fixture.element(Self.cancelLabel) == nil)
    }
}

extension WorkMessageBubblesHostedTests {
    @Test func givenCancellationOutcomeInBackgroundWindow_whenHosted_thenRequestIsConsumedWithoutActivation() async {
        // given
        let token = UUID()
        var consumed: Set<UUID> = []
        let fixture = RedesignHost(WorkMessageOutcomeView(text: "Queued message cancelled.", focusToken: token) { value in
            consumed.insert(value).inserted
        }.frame(width: 420), size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        fixture.window.orderOut(nil)
        let keyWindow = NSApp.keyWindow
        let wasActive = NSApp.isActive
        // when
        await fixture.settle { consumed.contains(token) }
        // then
        #expect(consumed == [token])
        #expect(NSApp.keyWindow === keyWindow)
        #expect(NSApp.isActive == wasActive)
        #expect(!fixture.window.isKeyWindow)
    }

    @Test(arguments: [false, true])
    func givenTaskOrWorkflowNodeLedger_whenTailHosted_thenUncertainPrecedesLiveAndQueuedFollows(workflowNode: Bool) async throws {
        // given
        var raw: [String: JSONValue] = ["messages": .array([
            .object(["id": .string("uncertain"), "seq": .number(1), "status": .string("delivering"),
                     "text": .string("Earlier uncertain message"), "reason": .string("Engine reason")]),
            .object(["id": .string("queued"), "seq": .number(2), "status": .string("queued"), "text": .string("Later queued message")])])]
        // Workflow uncertainty is the historical read-only state, not a standalone reason heuristic.
        if workflowNode {
            raw["workflow_run_id"] = .string("run")
            raw["task_id"] = .string("node")
            raw["messages"] = .array([
                .object(["id": .string("unknown"), "seq": .number(1), "status": .string("future-status"),
                         "text": .string("Earlier uncertain message")]),
                .object(["id": .string("queued"), "seq": .number(2), "status": .string("queued"), "text": .string("Later queued message")])])
        }
        let tail = ActivityFeedTailPresentation.standard(.init(workMessages: WorkMessageBubble.project(raw: raw),
                                                               liveStep: .init(text: "Live work", indicator: .singleDot)))
        let fixture = RedesignHost(ActivityFeedNativeTailContent(presentation: tail, actions: ActivityFeedNativeActions(), style: .transcript)
            .frame(width: 600), size: CGSize(width: 600, height: 500))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Later queued message") != nil && fixture.element("Live work") != nil }
        // then
        let earlier = try #require(fixture.element("Earlier uncertain message"))
        let live = try #require(fixture.element("Live work"))
        let later = try #require(fixture.element("Later queued message"))
        let earlierFrame = try #require(fixture.frame(earlier))
        let liveFrame = try #require(fixture.frame(live))
        let laterFrame = try #require(fixture.frame(later))
        // Accessibility frames use screen coordinates, increasing upwards.
        #expect(earlierFrame.midY > liveFrame.midY)
        #expect(liveFrame.midY > laterFrame.midY)
        if !workflowNode {
            #expect(fixture.element("Delivery could not be confirmed. The message is not requeued.\nEngine reason") != nil)
        }
    }
}

extension WorkMessageBubblesHostedTests {
    @Test func givenCurrentCancellation_whenOutcomeHosted_thenFocusTargetsRowOnceAndNeverAddsATabStop() async throws {
        // given
        let token = UUID()
        var consumed: Set<UUID> = []
        var accepted = 0
        func content() -> some View {
            WorkMessageOutcomeView(text: "Queued message cancelled.", focusToken: token) { value in
                let first = consumed.insert(value).inserted
                if first { accepted += 1 }
                return first
            }.frame(width: 420)
        }
        let fixture = RedesignHost(content(), size: CGSize(width: 420, height: 200))
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        try #require(NSApp.isActive, "UNVERIFIED: hosted focus requires an active test application")
        // when
        await fixture.settle { fixture.window.firstResponder is WorkMessageOutcomeFocusTarget }
        let target = try #require(fixture.window.firstResponder as? WorkMessageOutcomeFocusTarget)
        // then
        #expect(target.isAccessibilityElement())
        #expect(target.accessibilityLabel() == "Queued message cancelled.")
        #expect(target.isAccessibilityFocused())
        #expect(!target.canBecomeKeyView)
        #expect(target.acceptsFirstResponder)
        #expect(accepted == 1)
        // Reuse the row with the same one-shot request, after moving keyboard focus elsewhere.
        fixture.window.makeFirstResponder(nil)
        fixture.host.rootView = AnyView(content())
        await fixture.settle { fixture.element("Queued message cancelled.") != nil }
        #expect(accepted == 1)
        #expect(!(fixture.window.firstResponder is WorkMessageOutcomeFocusTarget))
    }
}
