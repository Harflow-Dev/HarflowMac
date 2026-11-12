import Foundation
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

/// Headless coverage of `ActivityFeedStyle`: the entry spacing the production
/// `ActivityFeedNativeEntries.build` resolves for `.standard` (today's values, as a guard) and
/// `.transcript` (24 before the first content, 16 between entries), the model equality that
/// drives remeasurement, and the live-append plan under the transcript style.
struct ActivityFeedStyleEntriesTests {

    // MARK: Fixtures

    private func row(_ seq: Int) -> ActivityRow {
        .single(ActivityFixture.text(seq), markdown: nil)
    }

    private func rows(_ range: ClosedRange<Int>) -> [ActivityRow] { range.map(row) }

    private func approvalCard(_ id: String) -> CallerApprovalCardModel {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string(id), "task_id": .string("t1"), "tool_name": .string("Bash"),
            "cwd": .string("/workspace/repo"), "freedom": .string("write_in_repo"),
            "scope": .string("exact_action_once"), "disposition": .string("pending"),
            "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "action": .object(["tool_name": .string("Bash"),
                               "input": .object(["command": .string("swift test")])])
        ])
        return CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request),
                                       pending: true, expanded: true, canRespond: true,
                                       notice: nil, submitting: false)
    }

    private func liveTail(approvals: [CallerApprovalCardModel] = []) -> ActivityFeedTailPresentation {
        .standard(.init(liveStep: .init(text: "Working", indicator: .singleDot), approvals: approvals))
    }

    private func model(_ rows: [ActivityRow], style: ActivityFeedStyle, emptyText: String? = nil,
                       tail: ActivityFeedTailPresentation = .absent) -> ActivityFeedNativeModel {
        ActivityFeedNativeModel(
            shownRows: rows, allRowIDs: rows.map(\.id), start: nil, emptyText: emptyText, horizontalPadding: 0,
            showsPromptBubble: false, style: style, expandedGroups: [], tailPresentation: tail,
            history: EventHistoryState(), paginationRevision: 0, visible: true, loading: false,
            approvalReveal: nil, activitySnapshot: nil)
    }

    private func build(_ rows: [ActivityRow], style: ActivityFeedStyle,
                       header: ActivityFeedNativeEntry.Header? = nil, emptyText: String? = nil,
                       tail: ActivityFeedTailPresentation = .absent) -> [ActivityFeedNativeEntry] {
        ActivityFeedNativeEntries.build(
            model: model(rows, style: style, emptyText: emptyText, tail: tail), header: header,
            following: false, mountedIDs: [])
    }

    private func spacings(_ entries: [ActivityFeedNativeEntry]) -> [CGFloat] { entries.map(\.topSpacing) }

    // MARK: Style values

    @Test func givenStandardStyle_whenAskedForSpacing_thenItReturnsTheCallersStandardValues() {
        // given / when / then
        #expect(ActivityFeedStyle.standard.spacing(first: true, standardFirst: 12, standardBetween: 20) == 12)
        #expect(ActivityFeedStyle.standard.spacing(first: false, standardFirst: 12, standardBetween: 20) == 20)
        #expect(ActivityFeedStyle.standard.horizontalPadding(standard: 24) == 24)
        #expect(!ActivityFeedStyle.standard.isTranscript)
    }

    @Test func givenTranscriptStyle_whenAskedForSpacing_thenItIgnoresTheCallersValues() {
        // given / when / then
        #expect(ActivityFeedStyle.transcript.spacing(first: true, standardFirst: 12, standardBetween: 20) == 24)
        #expect(ActivityFeedStyle.transcript.spacing(first: false, standardFirst: 12, standardBetween: 20) == 16)
        #expect(ActivityFeedStyle.transcript.spacing(first: true, standardFirst: 0, standardBetween: 0) == 24)
        #expect(ActivityFeedStyle.transcript.horizontalPadding(standard: 24) == 32)
        #expect(ActivityFeedStyle.transcript.isTranscript)
    }

    @Test func givenLaneStyle_whenAskedForSpacing_thenItUsesTheLaneBodyMetrics() {
        // given / when / then — `.hd-lane__body`: padding 16, gap 12; the transcript's row views otherwise.
        #expect(ActivityFeedStyle.lane.spacing(first: true, standardFirst: 12, standardBetween: 20) == 16)
        #expect(ActivityFeedStyle.lane.spacing(first: false, standardFirst: 12, standardBetween: 20) == 12)
        #expect(ActivityFeedStyle.lane.horizontalPadding(standard: 24) == 16)
        #expect(ActivityFeedStyle.lane.rowGap == 12)
        #expect(ActivityFeedStyle.lane.topPadding == 16)
        #expect(ActivityFeedStyle.lane.isTranscript && ActivityFeedStyle.lane.isLane)
        #expect(ActivityFeedStyle.transcript.rowGap == 16 && ActivityFeedStyle.transcript.topPadding == 24)
        #expect(ActivityFeedStyle.lane.pillFill == ActivityFeedStyle.transcript.pillFill)
        #expect(ActivityFeedStyle.lane.ruleColor == ActivityFeedStyle.transcript.ruleColor)
    }

    @Test func givenLaneRowsWithoutHeader_whenBuilt_thenFirstIsSixteenAndGapIsTwelve() {
        // given / when
        let entries = build(rows(1 ... 4), style: .lane)
        // then — four rows and the bottom sentinel.
        #expect(spacings(entries) == [16, 12, 12, 12, 0])
    }

    @Test func givenLaneTailAndApprovals_whenBuilt_thenTheyFollowAtTheLaneGap() {
        // given / when
        let after = build(rows(1 ... 2), style: .lane, tail: liveTail())
        // then — the live tail is a row gap below the last row.
        #expect(spacings(after) == [16, 12, 12, 0])
    }

    @Test func givenStyleChange_whenModelsCompared_thenStandardAndLaneModelsDiffer() {
        // given / when / then — a style change is part of the model, so it remeasures through the structural route.
        #expect(model(rows(1 ... 2), style: .standard) != model(rows(1 ... 2), style: .lane))
        #expect(model(rows(1 ... 2), style: .transcript) != model(rows(1 ... 2), style: .lane))
    }

    @Test func givenTranscriptMetrics_whenRead_thenTheyMatchTheApprovedTranscript() {
        // given / when / then — `.hd-transcript`: 760 column, padding 24 32 16, gap 16, so 696 of text.
        #expect(TaskScreenStyle.Transcript.maxWidth == 760)
        #expect(TaskScreenStyle.Transcript.paddingTop == 24)
        #expect(TaskScreenStyle.Transcript.paddingHorizontal == 32)
        #expect(TaskScreenStyle.Transcript.paddingBottom == 16)
        #expect(TaskScreenStyle.Transcript.gap == 16)
        #expect(TaskScreenStyle.Transcript.maxWidth - 2 * TaskScreenStyle.Transcript.paddingHorizontal == 696)
    }

    @Test func givenEnvironmentDefault_whenRead_thenStyleIsStandard() {
        // given / when
        let values = EnvironmentValues()
        // then
        #expect(values.activityFeedStyle == .standard)
    }

    // MARK: Standard entries (guard)

    @Test func givenStandardRowsWithoutHeader_whenBuilt_thenFirstIsTwelveAndGapIsTwenty() {
        // given / when
        let entries = build(rows(1 ... 4), style: .standard)
        // then — four rows and the bottom sentinel.
        #expect(spacings(entries) == [12, 20, 20, 20, 0])
    }

    @Test func givenStandardRowsWithHeader_whenBuilt_thenHeaderThenRowsAtTwenty() {
        // given / when
        let entries = build(rows(1 ... 2), style: .standard, header: .beginning)
        // then
        #expect(entries.first == .header(.beginning))
        #expect(spacings(entries) == [12, 20, 20, 0])
    }

    @Test func givenStandardEmptyFeed_whenBuilt_thenEmptyTextIsTwelveWithoutHeaderAndTwentyWith() {
        // given / when
        let bare = build([], style: .standard, emptyText: "Nothing yet")
        let headed = build([], style: .standard, header: .beginning, emptyText: "Nothing yet")
        // then
        #expect(spacings(bare) == [12, 0])
        #expect(spacings(headed) == [12, 20, 0])
    }

    @Test func givenStandardTail_whenBuiltAloneOrAfterRows_thenTailIsTwelveThenTwenty() {
        // given / when
        let alone = build([], style: .standard, tail: liveTail())
        let after = build(rows(1 ... 2), style: .standard, tail: liveTail())
        // then
        #expect(spacings(alone) == [12, 0])
        #expect(spacings(after) == [12, 20, 20, 0])
    }

    @Test func givenStandardApprovals_whenBuilt_thenEachApprovalIsTwelveAndTailFollowsAtTwenty() {
        // given
        let tail = liveTail(approvals: [approvalCard("a1"), approvalCard("a2")])
        // when
        let entries = build(rows(1 ... 1), style: .standard, tail: tail)
        // then — row, two approvals, tail, bottom.
        #expect(spacings(entries) == [12, 12, 12, 20, 0])
    }

    @Test func givenStandardApprovalsWithoutRows_whenBuilt_thenTailStaysAtTwelve() {
        // given / when
        let entries = build([], style: .standard, tail: liveTail(approvals: [approvalCard("a1")]))
        // then — the standard style does not count approvals as content for the tail spacing.
        #expect(spacings(entries) == [12, 12, 0])
    }

    // MARK: Transcript entries

    @Test func givenTranscriptRowsWithoutHeader_whenBuilt_thenFirstIsTwentyFourAndGapIsSixteen() {
        // given / when
        let entries = build(rows(1 ... 4), style: .transcript)
        // then
        #expect(spacings(entries) == [24, 16, 16, 16, 0])
    }

    @Test func givenTranscriptRowsWithHeader_whenBuilt_thenRowsAfterTheHeaderAreSixteen() {
        // given / when
        let entries = build(rows(1 ... 2), style: .transcript, header: .beginning)
        // then — the header opens the feed; its 24 is applied by the hosted root, not the entry.
        #expect(entries.first == .header(.beginning))
        #expect(spacings(entries).dropFirst() == [16, 16, 0])
    }

    @Test func givenTranscriptEmptyFeed_whenBuilt_thenEmptyTextOpensAtTwentyFourOrFollowsHeaderAtSixteen() {
        // given / when
        let bare = build([], style: .transcript, emptyText: "Nothing yet")
        let headed = build([], style: .transcript, header: .beginning, emptyText: "Nothing yet")
        // then
        #expect(spacings(bare) == [24, 0])
        #expect(spacings(headed).dropFirst() == [16, 0])
    }

    @Test func givenTranscriptTail_whenBuiltAloneOrAfterRows_thenTailIsTwentyFourThenSixteen() {
        // given / when
        let alone = build([], style: .transcript, tail: liveTail())
        let after = build(rows(1 ... 2), style: .transcript, tail: liveTail())
        // then
        #expect(spacings(alone) == [24, 0])
        #expect(spacings(after) == [24, 16, 16, 0])
    }

    @Test func givenTranscriptApprovalsAfterRows_whenBuilt_thenApprovalsAndTailAreSixteen() {
        // given
        let tail = liveTail(approvals: [approvalCard("a1"), approvalCard("a2")])
        // when
        let entries = build(rows(1 ... 1), style: .transcript, tail: tail)
        // then
        #expect(spacings(entries) == [24, 16, 16, 16, 0])
    }

    @Test func givenTranscriptApprovalsWithoutRows_whenBuilt_thenFirstApprovalOpensAtTwentyFourAndTailIsSixteen() {
        // given / when
        let entries = build([], style: .transcript, tail: liveTail(approvals: [approvalCard("a1"), approvalCard("a2")]))
        // then — approvals count as content, so the tail follows at the gap, not at the opening value.
        #expect(spacings(entries) == [24, 16, 16, 0])
    }

    @Test func givenTranscriptRowsWithGroups_whenBuilt_thenEveryRowKindUsesTheSameGap() {
        // given — a text row, a tool group, an edit, a text row.
        let built = ActivityRowsBuilder.build(from: [
            ActivityFixture.text(1), ActivityFixture.tool(2, category: "read", path: "/a.swift"),
            ActivityFixture.tool(3, category: "read", path: "/b.swift"), ActivityFixture.tool(4, category: "edit", path: "/a.swift"),
            ActivityFixture.text(5)
        ])
        // when
        let entries = build(built, style: .transcript)
        // then
        #expect(built.count == 4)
        #expect(spacings(entries) == [24, 16, 16, 16, 0])
    }

    // MARK: Equality and root inputs

    @Test func givenModelsThatDifferOnlyInStyle_whenCompared_thenTheyAreNotEqual() {
        // given
        let standard = model(rows(1 ... 3), style: .standard)
        let transcript = model(rows(1 ... 3), style: .transcript)
        // then — style is a root input: equality must see it so every row is remeasured.
        #expect(standard != transcript)
        #expect(transcript == model(rows(1 ... 3), style: .transcript))
    }

    @Test func givenModelDefault_whenStyleOmitted_thenItIsStandard() {
        // given
        let omitted = ActivityFeedNativeModel(
            shownRows: [], allRowIDs: [], start: nil, emptyText: nil, horizontalPadding: 0, showsPromptBubble: false,
            expandedGroups: [], tailPresentation: .absent, history: EventHistoryState(), paginationRevision: 0,
            visible: true, loading: false, approvalReveal: nil, activitySnapshot: nil)
        // then
        #expect(omitted.style == .standard)
    }

    // MARK: Live-append plan under the transcript style

    @Test func givenTranscriptFeed_whenOneRowAppended_thenPlannedAsTailInsertAtTheEnd() {
        // given
        let previous = build(rows(1 ... 50), style: .transcript)
        let next = build(rows(1 ... 51), style: .transcript)
        // when
        let result = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then — insertion index 50 is the bottom sentinel's slot, in post-removal coordinates.
        #expect(result == .tailInsert(removeLeading: 0, insertAt: 50, count: 1), "plan was \(result)")
        #expect(previous.last?.id == "activity-feed-bottom")
    }

    @Test func givenFullTranscriptWindow_whenOneRowAppendedAndOneLeaves_thenPlannedAsTailInsertWithSlide() {
        // given — 100 rows shown; the first leaves and row 101 arrives. Row 2 becomes first (16 -> 24).
        let previous = build(rows(1 ... 100), style: .transcript)
        let next = build(rows(2 ... 101), style: .transcript)
        // when
        let result = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then
        #expect(result == .tailInsert(removeLeading: 1, insertAt: 99, count: 1), "plan was \(result)")
        #expect(previous.first { $0.id == "t1#2" }?.topSpacing == CGFloat(16))
        #expect(next.first { $0.id == "t1#2" }?.topSpacing == 24)
    }

    @Test func givenTranscriptFeedWithApprovalsAndTail_whenRowAppended_thenInsertPrecedesApprovals() {
        // given
        let tail = liveTail(approvals: [approvalCard("a1")])
        let previous = build(rows(1 ... 5), style: .transcript, tail: tail)
        let next = build(rows(1 ... 6), style: .transcript, tail: tail)
        // when
        let result = ActivityFeedNativePlan.plan(previous: previous, next: next)
        // then
        #expect(result == .tailInsert(removeLeading: 0, insertAt: 5, count: 1), "plan was \(result)")
        #expect(previous[5].id == "activity-approval-a1")
    }

    @Test func givenTranscriptFeedWithBeginningHeader_whenRowAppended_thenHeaderIsMatchedAndInsertPlanned() {
        // given
        let previous = build(rows(1 ... 5), style: .transcript, header: .beginning)
        let next = build(rows(1 ... 6), style: .transcript, header: .beginning)
        // when / then
        #expect(ActivityFeedNativePlan.plan(previous: previous, next: next)
            == .tailInsert(removeLeading: 0, insertAt: 6, count: 1))
    }
}
