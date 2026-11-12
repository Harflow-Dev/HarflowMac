import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + lane

/// `ActivityFeedStyle.lane`: the transcript's row metrics at the lane's 12 pt row gap and 16 pt inset, with no
/// 760 column, mounted through the production Parallel lane (`ParallelColumnView`).
extension ActivityFeedTranscriptStyleHostedTests {
    private static let laneTask = "lane-task"

    @MainActor private struct LaneMount {
        let fixture: RedesignHost
        let table: ActivityFeedNativeTableView
        let size: CGSize

        func index(of id: String) -> Int? { table.owner?.entries.firstIndex { $0.id == id } }
        func height(of id: String) -> CGFloat? { index(of: id).map { table.rect(ofRow: $0).height } }
    }

    private func laneModel(rows: [ConversationTimelineRow], chrome: ParallelColumnChrome = .lane) -> ParallelColumnModel {
        let task = TaskInfo(.object(["task_id": .string(Self.laneTask), "backend": .string("codex"),
                                     "status": .string("completed"), "repo_path": .string("/tmp")]))!
        var model = ParallelColumnModel(id: Self.laneTask, task: task, title: "Lane", subtitle: "Codex", isBusy: false,
                                        outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
                                        activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
                                        summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        model.stepCountText = "\(rows.count) activity items"
        model.chrome = chrome
        return model
    }

    private func mountLane(_ model: ParallelColumnModel, width: CGFloat, height: CGFloat = 700) async throws -> LaneMount {
        _ = NSApplication.shared
        let size = CGSize(width: width, height: height)
        let fixture = RedesignHost(ParallelColumnView(model: model).frame(width: width, height: height), size: size)
        await fixture.settle {
            Self.tables(fixture.host).first?.owner?.model != nil && (Self.tables(fixture.host).first?.numberOfRows ?? 0) > 1
        }
        let table = try #require(Self.tables(fixture.host).first)
        await fixture.settle { fixture.hasStableRenderedFrame }
        return LaneMount(fixture: fixture, table: table, size: size)
    }

    private func laneRows() -> [ConversationTimelineRow] {
        let task = Self.laneTask
        let longPath = "/Users/example/repo/Sources/Module/Subdirectory/AnExtremelyLongFileNameThatCannotFitInOneLaneLine.swift"
        return [
            ActivityFixture.message(0, String(repeating: "Please fix the flaky test. ", count: 30), source: "initial", task: task),
            ActivityFixture.text(1, "Short note.", task: task),
            ActivityFixture.text(2, "Another short note.", task: task),
            ActivityFixture.tool(3, task: task, category: "read", path: "/repo/a.swift", live: false),
            ActivityFixture.tool(4, task: task, category: "edit", path: longPath, tool: "Edit", live: false),
            ActivityFixture.text(5, "Closing note.", task: task)
        ]
    }

    @Test func givenLaneFeedAt900_whenMounted_thenMetricsAreLaneMetricsAndNoReadingColumnApplies() async throws {
        // given / when
        let mounted = try await mountLane(laneModel(rows: laneRows()), width: 900)
        defer { mounted.fixture.close() }
        let owner = try #require(mounted.table.owner)
        let transcript = ActivityFeedStyle.transcript

        // then — style and insets.
        #expect(owner.model?.style == .lane)
        #expect(ActivityFeedStyle.lane.horizontalPadding(standard: 0) == 16)
        #expect(ActivityFeedStyle.lane.rowGap == 12 && transcript.rowGap == 16)
        #expect(ActivityFeedStyle.lane.topPadding == 16 && transcript.topPadding == 24)
        #expect(ActivityFeedStyle.lane.isTranscript && ActivityFeedStyle.lane.isLane && !transcript.isLane)
        // then — no 760 column: the table spans the lane (the 760 cap would leave 70 pt on each side).
        #expect(mounted.table.bounds.width > 880, "feed width \(mounted.table.bounds.width)")
        // then — entry spacing: the feed opens at the 16 pt top padding (its header) and rows follow at 12.
        guard case .header = try #require(owner.entries.first) else {
            Issue.record("the lane feed does not open with its header")
            return
        }
        let spacings = owner.entries.compactMap { entry -> CGFloat? in
            if case .row(let row) = entry { return row.topSpacing }
            return nil
        }
        #expect(!spacings.isEmpty && spacings.allSatisfy { $0 == 12 }, "\(spacings)")
        // then — rows use the transcript's own heights, 4 pt tighter per row (12 against 16 gap): prose lines are
        // the 22 pt transcript lines and tool heads the 28 pt transcript heads.
        let reference = try await mountFeed(rows: laneRows(), style: .transcript, width: 900)
        defer { reference.fixture.close() }
        for id in [Self.laneTask + "#1", Self.laneTask + "#2", Self.laneTask + "#3"] {
            let lane = try #require(mounted.height(of: id))
            let transcriptHeight = try #require(reference.height(of: id))
            #expect(abs((transcriptHeight - lane) - 4) < 1, "\(id): lane \(lane) transcript \(transcriptHeight)")
        }
        let tool = try #require(mounted.height(of: Self.laneTask + "#3"))
        #expect(tool - 12 >= 28 - 0.5, "tool head slot \(tool)")
    }

    /// The feed alone (no lane chrome) in a given style, for comparing row metrics with the lane's.
    private func mountFeed(rows: [ConversationTimelineRow], style: ActivityFeedStyle, width: CGFloat) async throws -> LaneMount {
        _ = NSApplication.shared
        let size = CGSize(width: width, height: 700)
        let feed = ActivityFeedView(rows: ActivityRowsBuilder.build(from: rows), start: nil, history: EventHistoryState(), isLoading: false,
                                    horizontalPadding: style.horizontalPadding(standard: 0), showsPromptBubble: false, style: style,
                                    state: ParallelColumnUIState(), onLoadMore: nil)
        let fixture = RedesignHost(feed.frame(width: width, height: 700), size: size)
        await fixture.settle { (Self.tables(fixture.host).first?.numberOfRows ?? 0) > 1 }
        let table = try #require(Self.tables(fixture.host).first)
        await fixture.settle { fixture.hasStableRenderedFrame }
        return LaneMount(fixture: fixture, table: table, size: size)
    }

    @Test func givenLaneFeedAt360_whenMounted_thenNothingOverflowsAndLongToolHeadsTruncate() async throws {
        // given / when
        let mounted = try await mountLane(laneModel(rows: laneRows()), width: ParallelLayout.minimumColumnWidth)
        defer { mounted.fixture.close() }
        let scroll = try #require(mounted.table.enclosingScrollView)

        // then — no horizontal overflow at the floor.
        #expect(!scroll.hasHorizontalScroller || scroll.horizontalScroller?.isHidden != false)
        #expect(mounted.table.bounds.width <= scroll.contentView.bounds.width + 1)
        // then — a long path never wraps the tool head: it stays as tall as a short one.
        let short = try #require(mounted.height(of: Self.laneTask + "#3"))
        let long = try #require(mounted.height(of: Self.laneTask + "#4"))
        #expect(abs(long - short) < 6, "long tool head \(long) vs short \(short)")
    }

    @Test func givenLaneFeedAt360_whenAUserMessageIsLong_thenTheBubbleStaysWithinEightyPercentOfTheContent() async throws {
        // given / when
        let mounted = try await mountLane(laneModel(rows: laneRows()), width: ParallelLayout.minimumColumnWidth)
        defer { mounted.fixture.close() }
        let first = try #require(mounted.index(of: Self.laneTask + "#0"))
        let rect = mounted.table.rect(ofRow: first)
        let band = mounted.table.convert(rect, to: mounted.fixture.host)

        // then — the filled bubble is at most 80% of the 328 pt content width (262.4), within a point or two.
        let ink = try #require(laneInkExtent(in: mounted.fixture.host, band: band), "the bubble rendered nothing")
        #expect(ink.maxX - ink.minX <= 0.8 * (ParallelLayout.minimumColumnWidth - 32) + 3, "bubble ink \(ink)")
        #expect(ink.minX >= 16 - 1 && ink.maxX <= ParallelLayout.minimumColumnWidth - 16 + 1, "bubble ink \(ink)")
    }

    @Test func givenLaneAndInspectorChrome_whenAStepCountIsSet_thenOnlyTheInspectorShowsTheCountLine() async throws {
        // given
        let lane = try await mountLane(laneModel(rows: laneRows()), width: 600)
        defer { lane.fixture.close() }
        let inspector = try await mountLane(laneModel(rows: laneRows(), chrome: .inspector), width: 600)
        defer { inspector.fixture.close() }

        // then
        #expect(lane.fixture.element("6 activity items") == nil)
        #expect(inspector.fixture.element("6 activity items") != nil)
        #expect(lane.table.owner?.model?.style == .lane)
        #expect(inspector.table.owner?.model?.style == .standard)
    }

    @Test func givenStandardAndLaneChrome_whenMountedWithTheSameRows_thenTheLaneRowsAreMeasuredWithTheLaneMetrics() async throws {
        // given — the same rows mounted in a standard-chrome (inspector) column and in a lane column (two mounts: a style
        // change on one mounted feed is covered by the transcript-to-standard promotion test).
        let rows = laneRows()
        let standard = try await mountLane(laneModel(rows: rows, chrome: .inspector), width: 600)
        defer { standard.fixture.close() }
        let before = try #require(standard.height(of: Self.laneTask + "#1"))

        // when
        let lane = try await mountLane(laneModel(rows: rows), width: 600)
        defer { lane.fixture.close() }
        let after = try #require(lane.height(of: Self.laneTask + "#1"))

        // then — the lane's 12 pt gap and 22 pt line replace the standard spacing and body line.
        #expect(abs(after - before) > 1, "standard \(before) and lane \(after) heights are equal")
    }

    /// The horizontal extent of what is drawn inside `band` that differs from the band's left-edge background.
    private func laneInkExtent(in view: NSView, band: CGRect) -> (minX: CGFloat, maxX: CGFloat)? {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / view.bounds.width
        func components(_ x: Int, _ y: Int) -> [CGFloat] {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return [0, 0, 0, 0] }
            return [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        }
        var minX = Int.max
        var maxX = -1
        let middle = Int(band.midY * scale)
        let background = components(0, middle)
        for x in 0 ..< bitmap.pixelsWide where zip(components(x, middle), background).contains(where: { abs($0 - $1) > 0.02 }) {
            minX = min(minX, x)
            maxX = max(maxX, x)
        }
        return maxX >= 0 ? (CGFloat(minX) / scale, CGFloat(maxX + 1) / scale) : nil
    }
}
