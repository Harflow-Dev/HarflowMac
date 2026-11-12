import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + lane end row

/// A settled lane's feed ends with one static line ("Done · 04:51") after the pinned bubbles and the outcome.
extension ActivityFeedTranscriptStyleHostedTests {
    private func endModel(status: String = "completed", rowCount: Int = 2, bubbles: [WorkMessageBubble] = [], outcome: String? = nil,
                          empty: String? = nil) -> ParallelColumnModel {
        let task = TaskInfo(.object(["task_id": .string("end-task"), "backend": .string("codex"), "status": .string(status),
                                     "repo_path": .string("/tmp"), "exit_code": .number(0), "duration_seconds": .number(291)]))!
        let rows = (0 ..< rowCount).map { index in
            ConversationTimelineRow(id: "end#\(index)", taskID: task.taskID, timestamp: nil,
                                    kind: .item(PreviewFixtures.textItem("Row \(index)", seq: index)), live: false)
        }
        var model = ParallelColumnModel(id: task.taskID, task: task, title: "End", subtitle: "", isBusy: false,
                                        outcomeMessage: outcome, showPrompt: false, rows: rows,
                                        activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
                                        summary: nil, onTapTakeover: nil, onTapOpenTask: {})
        model.status = ParallelLaneStatus.make(current: task, snapshot: nil, frame: nil)
        model.workMessages = bubbles
        model.emptyText = empty
        model.onSubmitMessage = { _, _ in true }
        model.onCancelMessage = { _ in }
        return model
    }

    private func mountEnd(_ model: ParallelColumnModel) async -> RedesignHost {
        _ = NSApplication.shared
        let fixture = RedesignHost(ParallelColumnView(model: model).frame(width: 380, height: 700), size: CGSize(width: 380, height: 700))
        await fixture.settle { Self.tables(fixture.host).first?.owner?.model != nil && (Self.tables(fixture.host).first?.numberOfRows ?? 0) > 1 }
        return fixture
    }

    private func endFrame(_ fixture: RedesignHost, _ label: String) throws -> CGRect {
        let element = try #require(fixture.element(label))
        return try #require(fixture.frame(element))
    }

    @Test func givenASettledLaneWithABubbleAndAnOutcome_whenMounted_thenTheEndRowComesLast() async throws {
        // given
        let bubble = WorkMessageBubble(id: "q", seq: 1, kind: .queued(canCancel: true, note: nil), text: "Run the suite again.")
        let model = endModel(bubbles: [bubble], outcome: "Queued message cancelled.")

        // when
        let fixture = await mountEnd(model)
        defer { fixture.close() }
        await fixture.settle { fixture.element("Done · 04:51") != nil && fixture.element("Queued message cancelled.") != nil }

        // then — window coordinates grow upward, so "after" means a smaller minY
        let end = try endFrame(fixture, "Done · 04:51")
        let outcome = try endFrame(fixture, "Queued message cancelled.")
        let queued = try endFrame(fixture, "Run the suite again.")
        #expect(end.maxY <= outcome.minY + 1, "end \(end), outcome \(outcome)")
        #expect(outcome.maxY <= queued.minY + 1)
    }

    @Test func givenASettledLane_whenMounted_thenTheEndRowIsOneStaticLine() async throws {
        // given / when
        let fixture = await mountEnd(endModel())
        defer { fixture.close() }
        await fixture.settle { fixture.element("Done · 04:51") != nil }

        // then
        let end = try endFrame(fixture, "Done · 04:51")
        #expect(end.height > 14 && end.height < 26, "one 13/18 line, not two: \(end)")
        #expect(fixture.element("Done · 04:51") != nil)
        let line = try #require(ParallelLaneStatus.settledLine(current: endModel().task, status: endModel().laneStatus))
        #expect(line.tone == .success && line.symbol == "checkmark")
    }

    @Test func givenAnEmptyActivityEntry_whenTheLaneIsSettled_thenTheEndRowStillFollowsIt() async throws {
        // given / when
        let fixture = await mountEnd(endModel(rowCount: 0, empty: "No activity to display."))
        defer { fixture.close() }
        await fixture.settle { fixture.element("No activity to display.") != nil && fixture.element("Done · 04:51") != nil }

        // then
        let empty = try endFrame(fixture, "No activity to display.")
        let end = try endFrame(fixture, "Done · 04:51")
        #expect(end.maxY <= empty.minY + 1, "end \(end), empty \(empty)")
        #expect(empty.height > 14 && empty.height < 30, "one 13/20 line: \(empty)")
    }

    @Test func givenARunningLane_whenMounted_thenThereIsNoEndRow() async throws {
        // given / when
        let fixture = await mountEnd(endModel(status: "running"))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Row 0") != nil }

        // then
        #expect(fixture.element("parallel-lane-end") == nil)
        #expect(ActivityFeedTailPresentation.standard(.init(settled: .init(text: "Done", tone: .success, symbol: nil)))
            .isVisible(with: ActivityFeedTail()))
    }
}
