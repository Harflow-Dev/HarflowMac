import AppKit
import HfTestUtilities
@testable import MainWindowFeature
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
}
