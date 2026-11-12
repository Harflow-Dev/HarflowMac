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
                                        outcomeMessage: outcome, showPrompt: false, rows: rows,
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

    @Test func givenAnUncertainBubble_whenMounted_thenItIsRenderedAsUncertainWithoutCancel() async throws {
        // given
        let uncertain = bubble("u", .uncertain("Delivery could not be confirmed. The message is not requeued."), "Summarise the change.")
        #expect(!uncertain.isPinned && !uncertain.canCancel)

        // when
        let fixture = try await mountTail(tailModel(bubbles: [uncertain], outcome: nil))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Summarise the change.") != nil }

        // then — the bubble and its rendered caption exist, so the absence of Cancel is not vacuous.
        _ = try #require(fixture.element("Summarise the change."))
        _ = try #require(fixture.element("Delivery uncertain"), "the rendered caption")
        #expect(fixture.element("Cancel queued message") == nil)
    }

    @Test func givenADeliveringBubble_whenMounted_thenItRendersQueuedWithoutCancel() async throws {
        // given
        let delivering = bubble("d", .queued(canCancel: false, note: nil), "Run the suite again.")

        // when
        let fixture = try await mountTail(tailModel(bubbles: [delivering], outcome: "Delivery is in progress."))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Run the suite again.") != nil && fixture.element("Delivery is in progress.") != nil }

        // then
        _ = try #require(fixture.element("Run the suite again."))
        _ = try #require(fixture.element("Queued"), "the rendered caption")
        #expect(fixture.element("Cancel queued message") == nil)
    }

    @Test func givenAQueuedBubbleWithCancel_whenMounted_thenCancelIsOffered() async throws {
        // given / when
        let fixture = try await mountTail(tailModel(bubbles: [bubble("q", .queued(canCancel: true, note: nil), "Run the suite again.")], outcome: nil))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Cancel queued message") != nil }

        // then
        _ = try #require(fixture.element("Cancel queued message"))
    }

    // MARK: - Outcome announcement

    private func announcements(_ model: ParallelColumnModel, waiting seconds: Double = 0.6) async throws -> [String] {
        var posted: [String] = []
        let previous = ParallelOutcomeAnnouncer.post
        ParallelOutcomeAnnouncer.post = { posted.append($0) }
        defer { ParallelOutcomeAnnouncer.post = previous }
        let fixture = try await mountTail(model)
        defer { fixture.close() }
        try await Task.sleep(for: .seconds(seconds))
        return posted
    }

    @Test func givenAnOutcomeThatCreatesTheTail_whenMounted_thenItIsAnnouncedOnce() async throws {
        // given / when
        let posted = try await announcements(tailModel(bubbles: [], outcome: "Announce tail outcome."))

        // then — other tests in the suite may share the announcer, so only this text is counted
        #expect(posted.filter { $0.contains("Announce tail outcome.") }.count == 1, "\(posted)")
    }

    @Test func givenAnOutcomeWhileTheLaneIsLoading_whenMounted_thenTheFootLineIsAnnouncedOnce() async throws {
        // given
        var model = tailModel(bubbles: [], outcome: "Announce foot outcome.", rowCount: 0)
        model.isLoading = true

        // when
        let posted = try await announcements(model)

        // then
        #expect(posted.filter { $0.contains("Announce foot outcome.") }.count == 1, "\(posted)")
    }

    @Test func givenAnnouncementsInOneBurst_whenTheWindowCloses_thenTheyPostAsOneAndIdenticalTextsCollapse() async throws {
        // given
        var posted: [String] = []
        let previous = ParallelOutcomeAnnouncer.post
        ParallelOutcomeAnnouncer.post = { posted.append($0) }
        defer { ParallelOutcomeAnnouncer.post = previous }

        // when — Cancel all sets the same outcome on three lanes
        for _ in 0 ..< 3 { ParallelOutcomeAnnouncer.announce("Announce burst.") }
        try await Task.sleep(for: .seconds(0.6))

        // then
        #expect(posted.filter { $0.contains("Announce burst.") }.count == 1, "\(posted)")
        #expect(!posted.contains { $0.contains("Announce burst. Announce burst.") })
    }
}

@Suite struct OutcomeAnnouncementTests {
    @Test func givenTheColumnState_whenOutcomesChange_thenOnlyANewOutcomeIsAnnounced() async {
        await MainActor.run {
            let state = ParallelColumnUIState()
            #expect(state.shouldAnnounce(outcome: nil) == false)
            #expect(state.shouldAnnounce(outcome: "Queued message cancelled.") == true)
            #expect(state.shouldAnnounce(outcome: "Queued message cancelled.") == false, "a recycled view does not repeat it")
            #expect(state.shouldAnnounce(outcome: "Delivery is in progress.") == true)
            #expect(state.shouldAnnounce(outcome: nil) == false)
            #expect(state.shouldAnnounce(outcome: "Delivery is in progress.") == true, "the same text announces again after it cleared")
        }
    }

    @Test func givenABurst_whenFlushed_thenUniqueTextsBecomeOneAnnouncement() {
        var burst = OutcomeAnnouncementCoalescer()
        burst.add("Cancelled.")
        burst.add("Cancelled.")
        burst.add("Couldn't cancel the message: busy")
        #expect(burst.flush() == "Cancelled. Couldn't cancel the message: busy")
        #expect(burst.flush() == nil)
    }
}
