import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

@Suite struct ActivityRowsBuilderTests {
    typealias Fixture = ActivityFixture

    // MARK: - Boundaries

    @Test func givenAdjacentToolsOfOneKind_whenBuilt_thenTheyFoldIntoOneCard() {
        // given
        let rows = [Fixture.tool(1, path: "/a.swift"), Fixture.tool(2, path: "/b.swift"), Fixture.tool(3, path: "/c.swift")]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.count == 1)
        #expect(result[0].group?.members.map(\.id) == ["t1#1", "t1#2", "t1#3"])
        #expect(result[0].group?.bucket == .read)
    }

    @Test func givenDifferentKindsInARow_whenBuilt_thenEachKindGetsItsOwnCard() {
        // given
        let rows = [
            Fixture.tool(1, path: "/a.swift"), Fixture.tool(2, category: "search"), Fixture.tool(3, category: "shell", command: "ls"),
            Fixture.tool(4, category: "mcp"), Fixture.tool(5, category: "web")
        ]
        // when
        let buckets = ActivityRowsBuilder.build(from: rows).compactMap { $0.group?.bucket }
        // then — mcp and web share the "other" bucket, so they fold together.
        #expect(buckets == [.read, .search, .shell, .other])
        #expect(ActivityRowsBuilder.build(from: rows).last?.group?.members.count == 2)
    }

    @Test func givenTextBetweenTools_whenBuilt_thenTheCardBreaksAndTheTextStaysInPlace() {
        // given
        let rows = [Fixture.tool(1), Fixture.text(2), Fixture.tool(3)]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.map(\.id) == ["t1#1", "t1#2", "t1#3"])
        #expect(result.compactMap(\.group).count == 2)
        #expect(result[1].singleRowID == "t1#2")
    }

    @Test func givenNoticesMessagesUndeliveredAndFinished_whenBuilt_thenEachBreaksTheCard() {
        // given
        let breakers: [TimelineItem.Body] = [
            .notice("n"), .message(text: "hello", source: "injected"), .undelivered(text: "x", reason: nil),
            .finished(status: "completed", exitCode: 0, summary: nil)
        ]
        for breaker in breakers {
            let rows = [Fixture.tool(1), Fixture.row(2, breaker), Fixture.tool(3)]
            // when
            let result = ActivityRowsBuilder.build(from: rows)
            // then
            #expect(result.count == 3)
            #expect(result[0].group?.members.count == 1)
            #expect(result[2].group?.members.count == 1)
        }
    }

    @Test func givenEditAndWriteCalls_whenBuilt_thenTheyStayIndividualRowsAndBreakTheCard() {
        // given
        let rows = [Fixture.tool(1), Fixture.tool(2, category: "edit", path: "/a.swift"), Fixture.tool(3, category: "write"), Fixture.tool(4)]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.count == 4)
        #expect(result[1].singleRowID == "t1#2")
        #expect(result[2].singleRowID == "t1#3")
        #expect(result[0].group != nil && result[3].group != nil)
    }

    @Test func givenAnActiveEdit_whenBuilt_thenItIsNotFoldedAndStaysPending() {
        // given — an edit still waiting for its result, between two reads.
        let rows = [Fixture.tool(1), Fixture.tool(2, category: "edit", path: "/a.swift", resolved: false), Fixture.tool(3)]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(result.count == 3)
        guard case .single(let row) = result[1], case .item(let item) = row.kind else {
            Issue.record("expected the edit as its own row")
            return
        }
        #expect(item.isRunningTool)
    }

    @Test func givenSeparatorsAndATaskChange_whenBuilt_thenTheCardBreaks() {
        // given
        let rows = [
            Fixture.tool(1, task: "t1"), Fixture.tool(2, task: "t1"),
            Fixture.separator("follow up", task: "t2"),
            Fixture.tool(1, task: "t2"),
            Fixture.tool(2, task: "t3")
        ]
        // when
        let result = ActivityRowsBuilder.build(from: rows)
        // then — t2 and t3 have adjacent reads but different tasks.
        #expect(result.map(\.id) == ["t1#1", "sep:t2", "t2#1", "t3#2"])
        #expect(result[0].group?.members.count == 2)
        #expect(result[2].group?.taskID == "t2")
        #expect(result[3].group?.taskID == "t3")
    }

    // MARK: - Identity and pending calls

    @Test func givenAGroupGrows_whenRebuilt_thenItsIdStaysTheFirstMembersRowId() {
        // given
        var rows = [Fixture.tool(1, path: "/a")]
        let before = ActivityRowsBuilder.build(from: rows)
        // when
        rows.append(Fixture.tool(2, path: "/b"))
        rows.append(Fixture.tool(3, path: "/c"))
        let after = ActivityRowsBuilder.build(from: rows)
        // then
        #expect(before[0].id == "t1#1")
        #expect(after[0].id == "t1#1")
        #expect(after[0].group?.members.count == 3)
    }

    @Test func givenMultiplePendingCalls_whenBuilt_thenEachStaysInPlaceAndTheCardIsRunning() {
        // given
        let rows = [Fixture.tool(1, resolved: false), Fixture.tool(2), Fixture.tool(3, resolved: false)]
        // when
        let group = ActivityRowsBuilder.build(from: rows)[0].group
        // then
        #expect(group?.members.map(\.id) == ["t1#1", "t1#2", "t1#3"])
        #expect(group?.members.map(\.isPending) == [true, false, true])
        #expect(group?.isRunning == true)
    }

    @Test func givenALaterResultArrivedFirst_whenBuilt_thenTheEarlierPendingCallKeepsItsPosition() {
        // given — out-of-order results: call 2 resolved while call 1 is still pending.
        let rows = [Fixture.tool(1, resolved: false), Fixture.tool(2, resolved: true)]
        // when
        let members = ActivityRowsBuilder.build(from: rows)[0].group?.members
        // then
        #expect(members?.first?.result == nil)
        #expect(members?.last?.result != nil)
    }

    @Test func givenUnresolvedCallsInATerminalTurn_whenBuilt_thenTheCardIsNotRunning() {
        // given — a terminal task: its rows are not live, so a missing result is "no result", not a spinner.
        let rows = [Fixture.tool(1, resolved: false, live: false), Fixture.tool(2, resolved: false, live: false)]
        // when
        let group = ActivityRowsBuilder.build(from: rows)[0].group
        // then
        #expect(group?.isRunning == false)
        #expect(group?.members.allSatisfy { !$0.isPending } == true)
        #expect(group?.members.allSatisfy { !$0.isFailed } == true)
    }

    // MARK: - Time range

    @Test func givenAGroup_whenFormattingTheTimeRange_thenItUsesTheFirstAndLastMemberTimestamps() {
        // given
        let rows = [Fixture.tool(1, at: 25), Fixture.tool(2, at: 40), Fixture.tool(3, at: 69)]
        let group = ActivityRowsBuilder.build(from: rows)[0].group
        // when
        let text = group?.timeRangeText(start: Fixture.base)
        // then
        #expect(text == "00:25 – 01:09")
    }

    @Test func givenAGroupWithOneInstant_whenFormattingTheTimeRange_thenItIsASingleTime() {
        // given
        let rows = [Fixture.tool(1, at: 25)]
        // when
        let text = ActivityRowsBuilder.build(from: rows)[0].group?.timeRangeText(start: Fixture.base)
        // then
        #expect(text == "00:25")
    }

    // MARK: - Sanity

    @Test func givenTwoThousandRows_whenBuilt_thenItFoldsInOnePassWithTheRightShape() {
        // given — 500 repeats of: 2 reads, 1 shell, text.
        var rows: [ConversationTimelineRow] = []
        for block in 0 ..< 500 {
            let base = block * 4
            rows.append(Fixture.tool(base + 1, path: "/f\(block).swift"))
            rows.append(Fixture.tool(base + 2, path: "/g\(block).swift"))
            rows.append(Fixture.tool(base + 3, category: "shell", command: "ls"))
            rows.append(Fixture.text(base + 4))
        }
        #expect(rows.count == 2000)
        // when
        let clock = ContinuousClock()
        var result: [ActivityRow] = []
        let elapsed = clock.measure { result = ActivityRowsBuilder.build(from: rows) }
        // then
        #expect(result.count == 1500)
        #expect(result.compactMap(\.group).count == 1000)
        #expect(result[0].group?.summary == "Read 2 files")
        #expect(elapsed < .seconds(5))
    }
}
