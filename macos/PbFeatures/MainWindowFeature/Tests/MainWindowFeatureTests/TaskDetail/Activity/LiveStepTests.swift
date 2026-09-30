import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

@Suite struct LiveStepTests {
    typealias Fixture = ActivityFixture

    @Test func givenAPendingRead_whenBuildingTheLiveStep_thenItReadsTheFileName() {
        #expect(LiveStep(rows: [Fixture.tool(1, path: "/repo/Sources/AppDelegate.swift", resolved: false)])?.text == "Reading AppDelegate.swift…")
    }

    @Test func givenAPendingReadWithoutAPath_whenBuildingTheLiveStep_thenItFallsBackToTheHeadline() {
        #expect(LiveStep(rows: [Fixture.tool(1, input: "some input", resolved: false)])?.text == "Reading some input…")
    }

    @Test func givenAPendingCommand_whenBuildingTheLiveStep_thenItNamesTheCommand() {
        #expect(LiveStep(rows: [Fixture.tool(1, category: "shell", command: "swift test", resolved: false)])?.text == "Running swift test…")
    }

    @Test func givenALongMultilineCommand_whenBuildingTheLiveStep_thenOnlyTheClippedFirstLineShows() {
        // given
        let command = "echo " + String(repeating: "x", count: 200) + "\nsecond line"
        // when
        let text = LiveStep(rows: [Fixture.tool(1, category: "shell", command: command, resolved: false)])?.text
        // then
        #expect(text?.hasPrefix("Running echo xxx") == true)
        #expect(text?.contains("second line") == false)
        #expect(text?.hasSuffix("……") == false)
        #expect((text?.count ?? 0) < 100)
    }

    @Test func givenAnotherKindOfPendingCall_whenBuildingTheLiveStep_thenItNamesTheTool() {
        #expect(LiveStep(rows: [Fixture.tool(1, category: "mcp", tool: "mocktail_list", resolved: false)])?.text == "mocktail_list…")
        #expect(LiveStep(rows: [Fixture.tool(1, category: "search", tool: "Grep", resolved: false)])?.text == "Grep…")
    }

    @Test func givenSeveralPendingCalls_whenBuildingTheLiveStep_thenTheLatestOneWins() {
        // given
        let rows = [Fixture.tool(1, path: "/a.swift", resolved: false), Fixture.tool(2, path: "/b.swift", resolved: false)]
        // when / then
        #expect(LiveStep(rows: rows)?.text == "Reading b.swift…")
    }

    @Test func givenNothingPending_whenBuildingTheLiveStep_thenThereIsNone() {
        #expect(LiveStep(rows: [Fixture.tool(1, path: "/a.swift"), Fixture.text(2)]) == nil)
        #expect(LiveStep(rows: []) == nil)
    }

    @Test func givenATerminalTask_whenBuildingTheLiveStep_thenUnresolvedCallsProduceNone() {
        // given — a terminal turn's rows are not live.
        let rows = [Fixture.tool(1, path: "/a.swift", resolved: false, live: false)]
        // when / then
        #expect(LiveStep(rows: rows) == nil)
    }

    @Test func givenAPendingCallInAnOlderTurn_whenBuildingTheLiveStep_thenOnlyTheLiveTurnCounts() {
        // given
        let rows = [
            Fixture.tool(1, task: "t1", path: "/old.swift", resolved: false, live: false),
            Fixture.tool(1, task: "t2", path: "/new.swift", resolved: false)
        ]
        // when / then
        #expect(LiveStep(rows: rows)?.text == "Reading new.swift…")
    }

    @Test func givenAPendingCall_whenBuildingTheFeed_thenTheLiveStepDoesNotRemoveTheCanonicalRow() {
        // given
        let rows = [Fixture.tool(1, path: "/a.swift", resolved: false)]
        // when
        let model = TimelinePaneModel(stepCountText: "1 step", rows: rows, start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)
        // then
        #expect(model.liveStep?.text == "Reading a.swift…")
        #expect(model.activityRows.first?.group?.members.map(\.id) == ["t1#1"])
        #expect(model.rows.count == 1)
    }
}
