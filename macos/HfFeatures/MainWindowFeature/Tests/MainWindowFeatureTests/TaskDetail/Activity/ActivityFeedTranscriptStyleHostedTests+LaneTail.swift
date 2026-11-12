import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + lane tail

/// The lane feed's tail: pinned queued bubbles, then the outcome line (not at the top of the body any more).
extension ActivityFeedTranscriptStyleHostedTests {
    private func tailModel(bubbles: [WorkMessageBubble], outcome: String?, rowCount: Int = 2) -> ParallelColumnModel {
        let task = TaskInfo(.object(["task_id": .string("tail-task"), "backend": .string("codex"),
                                     "status": .string("running"), "repo_path": .string("/tmp")]))!
        let rows = (0 ..< rowCount).map { index in
            ConversationTimelineRow(id: "tail#\(index)", taskID: task.taskID, timestamp: nil,
                                    kind: .item(PreviewFixtures.textItem("Row \(index)", seq: index)), live: false)
        }
        var model = ParallelColumnModel(id: task.taskID, task: task, title: "Tail", subtitle: "", isBusy: false,
                                        outcomeMessage: outcome, showPrompt: false, prompt: nil, rows: rows,
                                        activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
                                        summary: nil, onTapTakeover: nil, onTapOpenTask: {})
        model.workMessages = bubbles
        model.onSubmitMessage = { _, _ in true }
        model.onCancelMessage = { _ in }
        return model
    }

    private func mountTail(_ model: ParallelColumnModel) async throws -> RedesignHost {
        _ = NSApplication.shared
        let fixture = RedesignHost(ParallelColumnView(model: model).frame(width: 380, height: 700), size: CGSize(width: 380, height: 700))
        await fixture.settle { Self.tables(fixture.host).first?.owner?.model != nil && (Self.tables(fixture.host).first?.numberOfRows ?? 0) > 1 }
        return fixture
    }

    private func frameOf(_ fixture: RedesignHost, _ label: String) throws -> CGRect {
        let element = try #require(fixture.element(label))
        return try #require(fixture.frame(element))
    }

    private func bubble(_ id: String, _ kind: WorkMessageBubble.Kind, _ text: String) -> WorkMessageBubble {
        WorkMessageBubble(id: id, seq: 1, kind: kind, text: text)
    }

    @Test func givenAQueuedBubbleAndAnOutcome_whenMounted_thenTheOutcomeComesAfterTheBubbleAndNotAtTheTop() async throws {
        // given
        let model = tailModel(bubbles: [bubble("q", .queued(canCancel: true, note: nil), "Run the suite again.")],
                              outcome: "Queued message cancelled.")

        // when
        let fixture = try await mountTail(model)
        defer { fixture.close() }
        await fixture.settle { fixture.element("Queued message cancelled.") != nil && fixture.element("Run the suite again.") != nil }

        // then — window coordinates grow upward, so "after" means a smaller minY.
        let bubbleFrame = try frameOf(fixture, "Run the suite again.")
        let outcomeFrame = try frameOf(fixture, "Queued message cancelled.")
        #expect(outcomeFrame.maxY <= bubbleFrame.minY + 1, "outcome \(outcomeFrame), bubble \(bubbleFrame)")
    }

    @Test func givenAnOutcomeAlone_whenMounted_thenTheTailIsVisibleAndDrawsIt() async throws {
        // given / when
        let fixture = try await mountTail(tailModel(bubbles: [], outcome: "Delivery is in progress."))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Delivery is in progress.") != nil }

        // then
        #expect(fixture.element("Delivery is in progress.") != nil)
        let tail = ActivityFeedTailPresentation.standard(.init(outcome: "x"))
        #expect(tail.isVisible(with: ActivityFeedTail()))
        #expect(ActivityFeedTailPresentation.standard(.init()).isVisible(with: ActivityFeedTail()) == false)
    }

    @Test func givenAnUncertainBubble_whenMounted_thenItIsNotPinnedAndHasNoCancel() async throws {
        // given
        let uncertain = bubble("u", .uncertain("Delivery could not be confirmed. The message is not requeued."), "Summarise the change.")
        #expect(!uncertain.isPinned && !uncertain.canCancel)

        // when
        let fixture = try await mountTail(tailModel(bubbles: [uncertain], outcome: nil))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Summarise the change.") != nil }

        // then
        #expect(fixture.element("Delivery uncertain") != nil || fixture.element("Summarise the change.") != nil)
        #expect(fixture.element("Cancel queued message") == nil)
    }

    @Test func givenADeliveringBubble_whenMounted_thenItKeepsTheQueuedCaptionWithoutCancel() async throws {
        // given
        let delivering = bubble("d", .queued(canCancel: false, note: nil), "Run the suite again.")

        // when
        let fixture = try await mountTail(tailModel(bubbles: [delivering], outcome: "Delivery is in progress."))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Run the suite again.") != nil }

        // then
        #expect(delivering.caption == "Queued")
        #expect(fixture.element("Cancel queued message") == nil)
    }

    @Test func givenAQueuedBubbleWithCancel_whenMounted_thenCancelIsOffered() async throws {
        // given / when
        let fixture = try await mountTail(tailModel(bubbles: [bubble("q", .queued(canCancel: true, note: nil), "Run the suite again.")], outcome: nil))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Cancel queued message") != nil }

        // then
        #expect(fixture.element("Cancel queued message") != nil)
    }
}
