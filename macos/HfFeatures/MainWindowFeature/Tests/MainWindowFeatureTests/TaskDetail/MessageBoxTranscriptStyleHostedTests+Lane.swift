import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests + lane

/// `MessageBoxStyle.lane`: the Parallel lane's one-row composer.
extension MessageBoxTranscriptStyleHostedTests {
    static func laneModel(locked: Bool = false, busy: Bool = false, enabled: Bool = true) -> MessageBoxModel {
        MessageBoxModel(
            canSend: enabled && !locked, canContinue: false, isBusy: busy, label: "Message Codex", hint: "",
            placeholder: locked ? MessageBoxDisabledReason.takenOver.text : "Message Codex", buttonLabel: "Send",
            isLocked: locked, fieldAccessibilityLabel: "Message Codex", sendAccessibilityLabel: "Send to Codex")
    }

    private func lanePage(_ model: MessageBoxModel, sink: SubmitSink = SubmitSink(), withSendNow: Bool = false) -> RedesignHost {
        let view = MessageBoxView(model: model, onSubmitNow: withSendNow ? { sink.record("now:" + $0) } : nil, style: .lane) { sink.record($0) }
            .frame(width: 336)
            .padding(12)
            .background(TaskScreenStyle.Colors.pageBackground.color)
            .environment(\.hfReduceMotionOverride, true)
        return fixture(view, size: CGSize(width: 360, height: 200), dark: false)
    }

    @Test func givenLaneComposer_whenMounted_thenTheRowIs44PointsWithA28PointSendAndNoHintOrSendNow() async throws {
        // given
        let page = lanePage(Self.laneModel(), withSendNow: true)
        defer { page.close() }

        // when
        await page.settle { page.element("Send to Codex") != nil }

        // then — 8 + 28 + 8, and the surface is the only thing drawn: no hint, no Send now, even with onSubmitNow.
        let send = ComposerMeasure.frame("Send to Codex", in: page)
        #expect(abs(send.width - 28) <= 0.5 && abs(send.height - 28) <= 0.5, "send \(send.size)")
        let fitting = page.host.fittingSize.height - 24
        #expect(abs(fitting - 44) <= 1.5, "row height \(fitting)")
        #expect(page.element("Send now") == nil)
        #expect(page.element("Send queues; Send now requests immediate delivery when safe") == nil)
        #expect(page.element("⌘↩ to send") == nil)
    }

    @Test func givenLaneComposer_whenMounted_thenTheFieldAndSendCarryTheHarnessLabels() async {
        // given
        let page = lanePage(Self.laneModel())
        defer { page.close() }

        // when
        await page.settle { page.element("Send to Codex") != nil }

        // then
        #expect(page.element("Message Codex") != nil)
        #expect(page.element("Send to Codex") != nil)
    }

    @Test func givenLockedLaneComposer_whenMounted_thenTheRowIs56PointsWithTheLockTextAndNoField() async {
        // given
        let page = lanePage(Self.laneModel(locked: true))
        defer { page.close() }

        // when
        await page.settle { page.element(MessageBoxDisabledReason.takenOver.text) != nil }

        // then
        #expect(Self.editableField(in: page) == nil)
        let fitting = page.host.fittingSize.height - 24
        #expect(abs(fitting - 56) <= 1.5, "locked row height \(fitting)")
    }

    @Test func givenBusyLaneComposer_whenTextIsTyped_thenSendStaysDisabled() async throws {
        // given
        let page = lanePage(Self.laneModel(busy: true))
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))

        // when
        await Self.type("hello", into: field, in: page)

        // then
        let send = try #require(page.element("Send to Codex"))
        #expect(TaskStoppingHostedTests.isEnabled(send) == false)
    }

    @Test func givenLaneComposer_whenTextIsTypedAndSent_thenOnlyTheQueuePathRuns() async throws {
        // given
        let sink = SubmitSink()
        let page = lanePage(Self.laneModel(), sink: sink, withSendNow: true)
        defer { page.close() }
        await page.settle { Self.editableField(in: page) != nil }
        let field = try #require(Self.editableField(in: page))
        await Self.type("hello", into: field, in: page)

        // when
        await page.settle { page.element("Send to Codex").map { TaskStoppingHostedTests.isEnabled($0) == true } ?? false }
        #expect(page.press(try #require(page.element("Send to Codex"))))

        // then
        #expect(sink.values == ["hello"])
    }
}
