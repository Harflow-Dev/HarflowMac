import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelColumnCancelHostedTests

@MainActor @Suite(.serialized) struct ParallelColumnCancelHostedTests {
    private static let cancelLabel = "Cancel queued message"

    private func column(isBusy: Bool, hasHandler: Bool) throws -> ParallelColumnModel {
        let task = try #require(TaskInfo(.object([
            "task_id": .string("cancel-fixture"), "backend": .string("codex"),
            "status": .string("running"), "repo_path": .string("/tmp")
        ])))
        let rows = [ConversationTimelineRow(id: "row", taskID: task.id, timestamp: nil,
                                            kind: .item(PreviewFixtures.textItem("Working", seq: 0)), live: false)]
        var model = ParallelColumnModel(id: task.id, task: task, title: "Cancel fixture", subtitle: "Codex",
                                        isBusy: isBusy, outcomeMessage: nil, showPrompt: false, prompt: nil,
                                        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
                                        isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        model.workMessages = [WorkMessageBubble(id: "m", seq: 1, kind: .queued(canCancel: true, note: nil), text: "Queued note")]
        if hasHandler { model.onCancelMessage = { _ in } }
        return model
    }

    private func isEnabled(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
        return (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? false
    }

    @Test func givenColumnWithoutCancelHandler_whenHosted_thenCancelIsHidden() async throws {
        // given
        _ = NSApplication.shared
        let fixture = RedesignHost(ParallelColumnView(model: try column(isBusy: false, hasHandler: false)), size: CGSize(width: 420, height: 700))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Queued note") != nil }
        // then
        #expect(fixture.element("Queued note") != nil)
        #expect(fixture.element(Self.cancelLabel) == nil)
    }

    @Test func givenBusyColumnWithHandler_whenHosted_thenCancelIsDisabled() async throws {
        // given
        _ = NSApplication.shared
        let fixture = RedesignHost(ParallelColumnView(model: try column(isBusy: true, hasHandler: true)), size: CGSize(width: 420, height: 700))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element(Self.cancelLabel) != nil }
        // then
        let cancel = try #require(fixture.element(Self.cancelLabel))
        #expect(!isEnabled(cancel))
    }

    @Test func givenIdleColumnWithHandler_whenHosted_thenCancelIsEnabled() async throws {
        // given
        _ = NSApplication.shared
        let fixture = RedesignHost(ParallelColumnView(model: try column(isBusy: false, hasHandler: true)), size: CGSize(width: 420, height: 700))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element(Self.cancelLabel) != nil }
        // then
        let cancel = try #require(fixture.element(Self.cancelLabel))
        #expect(isEnabled(cancel))
    }
}
