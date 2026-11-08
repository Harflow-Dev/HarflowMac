import Foundation
import HfRepository
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

// MARK: - SummaryEntryScenario

/// One conversation's evidence for the Summary entry, with every condition satisfied by default. A test breaks
/// exactly one field. `input()` is what `TaskDetailVM` would hand the builder for the standalone mount.
struct SummaryEntryScenario {
    static let taskID = "t1"
    static let summary = "Fixed the retry path and added a regression test."

    var shows = true
    var taskStatus = "completed"
    var snapshotStatus: String? = "completed"
    var snapshotTaskID = SummaryEntryScenario.taskID
    var snapshotSummary: String? = SummaryEntryScenario.summary
    var listingSummary: String?
    var taskFields: [String: JSONValue] = [:]
    var items: [TimelineItem] = [SummaryEntryScenario.text(1, "Working through the retry path.")]
    var logState: EventLogState? = .final
    var forwardDrained = true
    var caughtUp = true
    var currentness = EventObservationCurrentness.current
    var reasons: Set<EventObservationReason> = []
    var hasOlder = false
    var earlierMembers: [ParallelMemberInput] = []
    var isBuilder = false
    var scope = FeatureObservationFixture.scope
    var previous: SummaryEntryDecision?
    var previousMarkdown: [String: StreamingMarkdownState] = [:]

    // MARK: Fixtures

    static func text(_ seq: Int, _ text: String, streaming: Bool = false) -> TimelineItem {
        TimelineItem(id: seq, at: ActivityFixture.base.addingTimeInterval(TimeInterval(seq)), body: .text(text, streaming: streaming))
    }

    static func tool(_ seq: Int, path: String) -> TimelineItem {
        let call = ActivityFixture.call("c\(seq)", tool: "Read", category: "read", path: path)
        return TimelineItem(id: seq, at: ActivityFixture.base.addingTimeInterval(TimeInterval(seq)),
                            body: .tool(call, ActivityFixture.result("c\(seq)")))
    }

    static func info(id: String = SummaryEntryScenario.taskID, status: String, summary: String? = nil,
                     fields: [String: JSONValue] = [:]) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string(id), "backend": .string("claude"), "status": .string(status)]
        if let summary { object["summary"] = .string(summary) }
        for (key, value) in fields { object[key] = value }
        return TaskInfo(.object(object))!
    }

    // MARK: Derived inputs

    var task: TaskInfo { Self.info(status: taskStatus, summary: listingSummary, fields: taskFields) }

    var snapshot: TaskInfo? {
        snapshotStatus.map { Self.info(id: snapshotTaskID, status: $0, summary: snapshotSummary, fields: taskFields) }
    }

    var frame: EventObservationFrame {
        EventObservationFrame(
            taskID: Self.taskID, scope: scope, items: items,
            history: EventObservationHistory(isLoading: false, hasOlder: hasOlder, caughtUp: caughtUp, forwardDrained: forwardDrained,
                                             reasons: reasons, currentness: currentness),
            logState: logState)
    }

    var current: ParallelMemberInput {
        ParallelMemberInput(task: task, items: items, prompt: nil, availability: .available, observation: frame)
    }

    func input() -> TaskDetailTimelineInput {
        TaskDetailTimelineInput(
            task: task, members: earlierMembers + [current], children: [], start: nil, isBuilder: isBuilder, events: [],
            snapshot: snapshot, history: EventHistoryState(), previousMarkdown: previousMarkdown, showsSummaryEntry: shows,
            previousSummaryDecision: previous)
    }

    func build() throws -> TaskDetailTimelinePresentation { try TaskDetailTimelineBuilder.build(input()) }
}

extension TaskDetailTimelinePresentation {
    /// The Summary entry when the run ends with one.
    var summaryEntry: SummaryEntry? {
        if case .summary(let entry) = activityRows.last { return entry }
        return nil
    }
}

// MARK: - TaskDetailSummaryEntryBuilderTests

/// The Summary entry's conditions (a) to (h), as `TaskDetailTimelineBuilder.build` evaluates them off the main actor.
@Suite struct TaskDetailSummaryEntryBuilderTests {

    @Test func givenEveryConditionHolds_whenBuilt_thenTheSummaryIsTheLastRow() throws {
        // given
        let scenario = SummaryEntryScenario()
        // when
        let presentation = try scenario.build()
        // then
        let entry = try #require(presentation.summaryEntry)
        #expect(entry.id == "t1#summary")
        #expect(entry.taskID == "t1")
        #expect(entry.text == SummaryEntryScenario.summary)
        #expect(presentation.activityRows.count == 2)
        #expect(presentation.activityRows.first?.id.hasSuffix("#1") == true)
        #expect(presentation.summaryEntryShown)
        #expect(presentation.summaryDecision == SummaryEntryDecision(
            memberID: "t1", rawSummary: SummaryEntryScenario.summary, scope: FeatureObservationFixture.scope, outcome: .shown))
        #expect(presentation.markdown["t1#summary"] == entry.markdown)
    }

    @Test func givenTheMountIsNotStandalone_whenBuilt_thenThereIsNoEntryAndNoDecision() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.shows = false
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(!presentation.summaryEntryShown)
        #expect(presentation.summaryDecision == nil)
        #expect(presentation.activityRows.count == 1)
    }

    @Test func givenAFollowUpMemberIsCurrent_whenTheEarlierTaskIsTheShownOne_thenThereIsNoEntry() throws {
        // given — the shown task is the first member, but a follow-up is the conversation's last member.
        var scenario = SummaryEntryScenario()
        let followUp = ParallelMemberInput(
            task: SummaryEntryScenario.info(id: "t2", status: "running"), items: [SummaryEntryScenario.text(1, "Next step.")],
            prompt: nil, availability: .available)
        let first = scenario.current
        scenario.earlierMembers = []
        var input = scenario.input()
        input = TaskDetailTimelineInput(
            task: input.task, members: [first, followUp], children: [], start: nil, isBuilder: false, events: [],
            snapshot: input.snapshot, history: EventHistoryState(), showsSummaryEntry: true)
        // when
        let presentation = try TaskDetailTimelineBuilder.build(input)
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenAFollowUpMemberRuns_whenAnEntryWasShown_thenItIsRemoved() throws {
        // given
        let scenario = SummaryEntryScenario()
        let before = try scenario.build()
        try #require(before.summaryEntry != nil)
        let followUp = ParallelMemberInput(
            task: SummaryEntryScenario.info(id: "t2", status: "running"), items: [SummaryEntryScenario.text(1, "Next step.")],
            prompt: nil, availability: .available)
        // when
        let input = TaskDetailTimelineInput(
            task: SummaryEntryScenario.info(id: "t2", status: "running"), members: [scenario.current, followUp], children: [],
            start: nil, isBuilder: false, events: [], snapshot: nil, history: EventHistoryState(), previousMarkdown: before.markdown,
            showsSummaryEntry: true, previousSummaryDecision: before.summaryDecision)
        let after = try TaskDetailTimelineBuilder.build(input)
        // then
        #expect(after.summaryEntry == nil)
        #expect(!after.summaryEntryShown)
        #expect(after.summaryDecision == nil)
        #expect(after.markdown["t1#summary"] == nil)
    }

    @Test(arguments: ["running", "failed", "cancelled"])
    func givenTheTaskIsNotCompleted_whenBuilt_thenThereIsNoEntry(status: String) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.taskStatus = status
        scenario.snapshotStatus = status
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenOnlyAListingRow_whenBuilt_thenTheFallbackGivesNoEntry() throws {
        // given — the summary is on the bare listing row; no snapshot of the member exists.
        var scenario = SummaryEntryScenario()
        scenario.snapshotStatus = nil
        scenario.listingSummary = SummaryEntryScenario.summary
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenASnapshotWhoseStatusDiffersFromTheShownStatus_whenBuilt_thenThereIsNoEntry() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.snapshotStatus = "running"
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
    }

    @Test func givenASnapshotOfAnotherTask_whenBuilt_thenThereIsNoEntry() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.snapshotTaskID = "other"
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
    }

    @Test(arguments: [nil, .open, .settling, .incomplete, .unknown, .unavailable] as [EventLogState?])
    func givenTheLogIsNotFinal_whenBuilt_thenThereIsNoEntry(state: EventLogState?) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.logState = state
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenTheForwardLogIsNotDrained_whenBuilt_thenThereIsNoEntry() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.forwardDrained = false
        // when / then
        #expect(try scenario.build().summaryEntry == nil)
    }

    @Test func givenHistoryIsNotCaughtUp_whenBuilt_thenThereIsNoEntry() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.caughtUp = false
        // when / then
        #expect(try scenario.build().summaryEntry == nil)
    }

    @Test(arguments: [EventObservationCurrentness.reconnecting, .sourceChangePending])
    func givenTheSourceIsNotCurrent_whenBuilt_thenThereIsNoEntry(currentness: EventObservationCurrentness) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.currentness = currentness
        // when / then
        #expect(try scenario.build().summaryEntry == nil)
    }

    @Test(arguments: Array(TaskDetailSummaryEntryRule.lossReasons).sorted { $0.rawValue < $1.rawValue }, [true, false])
    func givenEvidenceLoss_whenBuilt_thenTheEntryIsWithheldWithOrWithoutAText(reason: EventObservationReason, withText: Bool) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.reasons = [reason]
        if !withText { scenario.items = [] }
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenTheLossReasonSet_whenRead_thenItIsExactlyTheFiveUnprovableReasons() {
        // given / when / then
        #expect(TaskDetailSummaryEntryRule.lossReasons == [
            .unsupportedPayload, .normalizationLoss, .skippedRecords, .gaps, .ambiguousOrder
        ])
    }

    @Test(arguments: [EventObservationReason.historicalLimit, .capacity, .ambiguousCall])
    func givenAReasonOutsideTheLossSet_whenBuilt_thenTheEntryStillShows(reason: EventObservationReason) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.reasons = [reason]
        // when / then
        #expect(try scenario.build().summaryEntry != nil)
    }

    @Test func givenNoTextAndOlderHistory_whenBuilt_thenTheEntryIsUndecidedAndWithheld() throws {
        // given — a tool-only final turn with older pages not yet read.
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.tool(1, path: "/repo/a.swift")]
        scenario.hasOlder = true
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenNoTextAndNoOlderHistory_whenBuilt_thenTheEntryShows() throws {
        // given — the whole log is read and no assistant text exists, so nothing can repeat the summary.
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.tool(1, path: "/repo/a.swift")]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == SummaryEntryScenario.summary)
        #expect(presentation.activityRows.count == 2)
    }

    @Test func givenATextAndOlderHistory_whenBuilt_thenTheEntryShows() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.hasOlder = true
        // when / then
        #expect(try scenario.build().summaryEntry != nil)
    }

    @Test(arguments: ["", "   ", " \n\t  ", nil] as [String?])
    func givenAnEmptyOrBlankSummary_whenBuilt_thenThereIsNoEntry(summary: String?) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.snapshotSummary = summary
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenABlankSnapshotSummaryAndAListingSummary_whenBuilt_thenTheSnapshotWins() throws {
        // given — the snapshot is the fresher source, even when it is blank.
        var scenario = SummaryEntryScenario()
        scenario.snapshotSummary = "  "
        scenario.listingSummary = "From the listing."
        // when / then
        #expect(try scenario.build().summaryEntry == nil)
    }

    @Test func givenASnapshotWithoutASummaryAndAListingSummary_whenBuilt_thenTheListingSummaryShows() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.snapshotSummary = nil
        scenario.listingSummary = "From the listing."
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == "From the listing.")
        #expect(presentation.summaryDecision?.rawSummary == "From the listing.")
    }

    @Test func givenAManagedWorkflowResultError_whenBuilt_thenThereIsNoEntry() throws {
        // given — the workflow-output-error row already carries the reason.
        var scenario = SummaryEntryScenario()
        scenario.taskFields = ["workflow_result_error": .string("The node returned prose, not its contract.")]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    // MARK: Order and markdown

    @Test func givenToolGroupsInTheLastTurn_whenBuilt_thenTheSummaryFollowsThem() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [
            SummaryEntryScenario.text(1, "Reading the files."), SummaryEntryScenario.tool(2, path: "/repo/a.swift"),
            SummaryEntryScenario.tool(3, path: "/repo/b.swift")
        ]
        // when
        let presentation = try scenario.build()
        // then
        let rows = presentation.activityRows
        try #require(rows.count == 3)
        #expect(rows[1].group != nil)
        #expect(rows[2].id == "t1#summary")
    }

    @Test func givenAPreviousPresentation_whenRebuiltWithTheSameSummary_thenTheMarkdownStateIsReused() throws {
        // given
        var scenario = SummaryEntryScenario()
        let first = try scenario.build()
        scenario.previousMarkdown = first.markdown
        // when
        let second = try scenario.build()
        // then
        #expect(second.markdown["t1#summary"] == first.markdown["t1#summary"])
        #expect(second.summaryEntry == first.summaryEntry)
        #expect(second.activityRows == first.activityRows)
        #expect(second.markdown == first.markdown)
        #expect(second.summaryDecision == first.summaryDecision)
    }

    @Test func givenAChangedSummaryText_whenRebuilt_thenTheEntryAndItsMarkdownFollow() throws {
        // given
        var scenario = SummaryEntryScenario()
        let first = try scenario.build()
        scenario.previousMarkdown = first.markdown
        scenario.snapshotSummary = "Rewrote the retry path instead."
        // when
        let second = try scenario.build()
        // then
        #expect(second.summaryEntry?.text == "Rewrote the retry path instead.")
        #expect(second.summaryEntry != first.summaryEntry)
        #expect(second.markdown["t1#summary"] != first.markdown["t1#summary"])
        #expect(second != first)
    }

    @Test func givenBuilderInputs_whenBuilt_thenTheBuilderProjectionOfTheSummaryIsShown() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.isBuilder = true
        let expected = try #require(WorkflowBuilderPresentation.summary(SummaryEntryScenario.summary))
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == expected)
        #expect(presentation.summaryDecision?.rawSummary == SummaryEntryScenario.summary)
    }

    // MARK: Presentation value

    @Test func givenAShownEntry_whenHistoryStartsLoading_thenThePublishedEntryStateSurvives() throws {
        // given
        let presentation = try SummaryEntryScenario().build()
        try #require(presentation.summaryEntryShown)
        // when
        let loading = presentation.loadingHistory()
        // then
        #expect(loading.summaryEntryShown)
        #expect(loading.summaryDecision == presentation.summaryDecision)
        #expect(loading.activityRows == presentation.activityRows)
    }

    @Test func givenTwoPresentationsThatDifferOnlyInTheEntry_whenCompared_thenTheyAreNotEqual() throws {
        // given
        var withoutEntry = SummaryEntryScenario()
        withoutEntry.shows = false
        // when
        let shown = try SummaryEntryScenario().build()
        let hidden = try withoutEntry.build()
        // then
        #expect(shown != hidden)
        #expect(shown.summaryEntryShown != hidden.summaryEntryShown)
    }
}

// MARK: - TaskDetailSummaryEntryDuplicateTests

/// D-SUMMARY-DUP: the entry is suppressed exactly when the raw reported summary equals the member's last assistant
/// message byte for byte.
@Suite struct TaskDetailSummaryEntryDuplicateTests {
    private let summary = SummaryEntryScenario.summary

    @Test func givenTheFinalMessageEqualsTheSummary_whenBuilt_thenTheEntryIsSuppressedButDecided() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(!presentation.summaryEntryShown)
        let expected = SummaryEntryDecision(
            memberID: "t1", rawSummary: summary, scope: FeatureObservationFixture.scope, outcome: .suppressed)
        #expect(presentation.summaryDecision == expected)
        #expect(presentation.activityRows.count == 1)
        #expect(presentation.markdown["t1#summary"] == nil)
    }

    @Test func givenTheFinalMessageDiffersOnlyInTrailingWhitespace_whenBuilt_thenTheEntryShows() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary + "\n")]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == summary)
        #expect(presentation.summaryDecision?.outcome == .shown)
    }

    @Test func givenCanonicallyEquivalentButDifferentlyEncodedText_whenBuilt_thenTheEntryShows() throws {
        // given — precomposed and decomposed forms of the same word compare equal as Strings, not as bytes.
        let composed = "Caf\u{00E9} handling fixed."
        let decomposed = "Cafe\u{0301} handling fixed."
        try #require(composed == decomposed)
        var scenario = SummaryEntryScenario()
        scenario.snapshotSummary = composed
        scenario.items = [SummaryEntryScenario.text(1, decomposed)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == composed)
        #expect(presentation.summaryDecision?.outcome == .shown)
    }

    @Test func givenAStreamingLastText_whenItEqualsTheSummary_thenItNeverSuppresses() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary, streaming: true)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == summary)
        #expect(presentation.summaryDecision?.outcome == .shown)
    }

    @Test func givenAnEarlierIdenticalTextFollowedByAStreamingOne_whenBuilt_thenTheEntryShows() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary), SummaryEntryScenario.text(2, "Still writing", streaming: true)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry != nil)
        #expect(presentation.summaryDecision?.outcome == .shown)
    }

    @Test func givenAnEarlierIdenticalTextFollowedByADifferentFinalText_whenBuilt_thenOnlyTheLastTextCounts() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary), SummaryEntryScenario.text(2, "Done.")]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry != nil)
    }

    @Test func givenAMatchingEarlierTextFollowedByALostRecord_whenBuilt_thenTheEntryIsUndecided() throws {
        // given — a skipped record could have held a later, different final message.
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        scenario.reasons = [.skippedRecords]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenAnEarlierMemberRepeatsTheSummary_whenTheLastMemberDiffers_thenOnlyTheLastMemberCounts() throws {
        // given
        var scenario = SummaryEntryScenario()
        let earlier = SummaryEntryScenario.info(id: "t0", status: "completed")
        scenario.earlierMembers = [ParallelMemberInput(
            task: earlier, items: [SummaryEntryScenario.text(1, summary)], prompt: nil, availability: .available,
            observation: EventObservationFrame(taskID: "t0", scope: FeatureObservationFixture.scope,
                                               items: [SummaryEntryScenario.text(1, summary)], history: .init(), logState: .open))]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == summary)
        #expect(presentation.summaryDecision?.memberID == "t1")
    }

    @Test func givenAManagedEnvelopeEqualToTheFinalMessage_whenBuilt_thenRawValuesSuppress() throws {
        // given — the final assistant message is the raw envelope the node reported.
        let envelope = #"{"status":"succeeded","result":{"answer":"Done"},"evidence":["checked"]}"#
        var scenario = SummaryEntryScenario()
        scenario.taskFields = ["workflow_role": .string("node"), "execution_contract": .string("delegation")]
        scenario.snapshotSummary = envelope
        scenario.items = [SummaryEntryScenario.text(1, envelope)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        let expected = SummaryEntryDecision(
            memberID: "t1", rawSummary: envelope, scope: FeatureObservationFixture.scope, outcome: .suppressed)
        #expect(presentation.summaryDecision == expected)
    }

    @Test func givenAManagedEnvelopeThatDiffersFromTheFinalMessage_whenBuilt_thenTheProjectedTextIsDisplayed() throws {
        // given
        let envelope = #"{"status":"succeeded","result":{"answer":"Done"},"evidence":["checked"]}"#
        var scenario = SummaryEntryScenario()
        scenario.taskFields = ["workflow_role": .string("node"), "execution_contract": .string("delegation")]
        scenario.snapshotSummary = envelope
        scenario.items = [SummaryEntryScenario.text(1, "All finished.")]
        let expected = try #require(WorkflowNodePresentation.summary(envelope, task: scenario.task))
        // when
        let presentation = try scenario.build()
        // then
        let entry = try #require(presentation.summaryEntry)
        #expect(entry.text == expected)
        #expect(entry.text != envelope)
        #expect(entry.text.hasPrefix("Succeeded"))
        #expect(presentation.summaryDecision?.rawSummary == envelope)
    }
}
