import Foundation
import HfRepository
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

// MARK: - TaskDetailSummaryEntryStickinessTests

/// Behaviour 3: a decided entry survives a transient drop of `forwardDrained`, `caughtUp` or `currentness` for the
/// same member, raw summary and source. The per-build gates (final log state, status, summary, mount, member) still
/// apply to a reused decision; loss reasons and the text-evidence rule apply only when a new decision is made.
@Suite struct TaskDetailSummaryEntryStickinessTests {
    private let summary = SummaryEntryScenario.summary

    enum Drop: CaseIterable, CustomTestStringConvertible {
        case forwardDrained, caughtUp, reconnecting, sourceChangePending

        var testDescription: String {
            switch self {
            case .forwardDrained: "forwardDrained"
            case .caughtUp: "caughtUp"
            case .reconnecting: "reconnecting"
            case .sourceChangePending: "sourceChangePending"
            }
        }

        func apply(to scenario: inout SummaryEntryScenario) {
            switch self {
            case .forwardDrained: scenario.forwardDrained = false
            case .caughtUp: scenario.caughtUp = false
            case .reconnecting: scenario.currentness = .reconnecting
            case .sourceChangePending: scenario.currentness = .sourceChangePending
            }
        }
    }

    private func decision(_ outcome: SummaryEntryDecision.Outcome, member: String = "t1", raw: String? = nil,
                          scope: EventObservationScope = FeatureObservationFixture.scope) -> SummaryEntryDecision {
        SummaryEntryDecision(memberID: member, rawSummary: raw ?? summary, scope: scope, outcome: outcome)
    }

    @Test(arguments: Drop.allCases)
    func givenAShownEntry_whenCompletenessDropsTransiently_thenTheEntryIsKept(drop: Drop) throws {
        // given
        var scenario = SummaryEntryScenario()
        let shown = try scenario.build()
        try #require(shown.summaryEntry != nil)
        scenario.previous = shown.summaryDecision
        scenario.previousMarkdown = shown.markdown
        drop.apply(to: &scenario)
        // when
        let kept = try scenario.build()
        // then
        #expect(kept.summaryEntry == shown.summaryEntry)
        #expect(kept.summaryDecision == shown.summaryDecision)
        #expect(kept.summaryEntryShown)
    }

    @Test(arguments: Drop.allCases)
    func givenASuppressedEntry_whenCompletenessDropsTransiently_thenItStaysSuppressed(drop: Drop) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        scenario.previous = decision(.suppressed)
        drop.apply(to: &scenario)
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == decision(.suppressed))
    }

    @Test(arguments: Drop.allCases)
    func givenNoPreviousDecision_whenCompletenessIsMissing_thenNothingIsDecided(drop: Drop) throws {
        // given
        var scenario = SummaryEntryScenario()
        drop.apply(to: &scenario)
        // when / then
        #expect(try scenario.build().summaryDecision == nil)
    }

    @Test(arguments: Drop.allCases)
    func givenADecisionForAnotherSummaryText_whenCompletenessDrops_thenTheEntryIsWithheld(drop: Drop) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown, raw: "An earlier summary.")
        drop.apply(to: &scenario)
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test(arguments: Drop.allCases)
    func givenADecisionForAnotherMember_whenCompletenessDrops_thenTheEntryIsWithheld(drop: Drop) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown, member: "t0")
        drop.apply(to: &scenario)
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test(arguments: [nil, .open, .settling, .incomplete, .unknown, .unavailable] as [EventLogState?])
    func givenAShownEntry_whenTheLogStopsBeingFinal_thenTheEntryIsWithdrawn(state: EventLogState?) throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.logState = state
        scenario.currentness = .reconnecting
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test(arguments: Array(TaskDetailSummaryEntryRule.lossReasons).sorted { $0.rawValue < $1.rawValue })
    func givenAShownEntry_whenEvidenceIsLostLater_thenTheDecidedEntryIsKept(reason: EventObservationReason) throws {
        // given — loss reasons gate only the establishing of a decision.
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.forwardDrained = false
        scenario.reasons = [reason]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryDecision == decision(.shown))
        #expect(presentation.summaryEntry?.text == summary)
    }

    @Test func givenAShownEntry_whenTheTextEvidenceIsMissingLater_thenTheDecidedEntryIsKept() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.items = [SummaryEntryScenario.tool(1, path: "/repo/a.swift")]
        scenario.hasOlder = true
        scenario.forwardDrained = false
        // when / then
        #expect(try scenario.build().summaryEntry?.text == summary)
    }

    @Test func givenNoPreviousDecision_whenTheTextEvidenceIsMissingDuringADrop_thenNothingIsDecided() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.items = [SummaryEntryScenario.tool(1, path: "/repo/a.swift")]
        scenario.hasOlder = true
        scenario.forwardDrained = false
        // when / then
        #expect(try scenario.build().summaryDecision == nil)
    }

    @Test func givenAShownEntry_whenTheLastTextNowMatchesUnderAFinalCompleteLog_thenItStaysShown() throws {
        // given — dedup runs only when a decision is established.
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryDecision?.outcome == .shown)
        #expect(presentation.summaryEntry?.text == summary)
    }

    @Test func givenASuppressedEntry_whenTheLastTextNowDiffers_thenItStaysSuppressed() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.suppressed)
        scenario.items = [SummaryEntryScenario.text(1, "A different closing message.")]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryDecision == decision(.suppressed))
        #expect(presentation.summaryEntry == nil)
    }

    @Test func givenAShownEntry_whenTheSourceChanges_thenTheDecisionIsNotReusedDuringADrop() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.scope = EventObservationScope(sessionID: FeatureObservationFixture.scope.sessionID,
                                               sourceID: UUID(), windowID: FeatureObservationFixture.scope.windowID)
        scenario.currentness = .sourceChangePending
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == nil)
    }

    @Test func givenAShownEntry_whenTheWindowIsReplacedAndTheLogIsComplete_thenTheDecisionIsMadeAgainForTheNewScope() throws {
        // given — the new window's last text now matches, so a fresh decision suppresses.
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        let replaced = EventObservationScope(sessionID: FeatureObservationFixture.scope.sessionID,
                                             sourceID: FeatureObservationFixture.scope.sourceID, windowID: UUID())
        scenario.scope = replaced
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry == nil)
        #expect(presentation.summaryDecision == decision(.suppressed, scope: replaced))
    }

    @Test func givenAShownEntry_whenTheSummaryOrTheStatusIsGoneDuringADrop_thenTheEntryIsWithdrawn() throws {
        // given
        var blank = SummaryEntryScenario()
        blank.previous = decision(.shown)
        blank.forwardDrained = false
        blank.snapshotSummary = ""
        var running = SummaryEntryScenario()
        running.previous = decision(.shown)
        running.forwardDrained = false
        running.taskStatus = "running"
        running.snapshotStatus = "running"
        // when / then
        #expect(try blank.build().summaryDecision == nil)
        #expect(try running.build().summaryDecision == nil)
    }

    @Test func givenAShownEntry_whenTheSummaryTextChangesWhileComplete_thenTheDecisionIsRemade() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.snapshotSummary = "A rewritten summary."
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryEntry?.text == "A rewritten summary.")
        #expect(presentation.summaryDecision == decision(.shown, raw: "A rewritten summary."))
    }

    @Test func givenAShownEntry_whenCompletenessReturns_thenTheDecisionIsTheSame() throws {
        // given
        var scenario = SummaryEntryScenario()
        let first = try scenario.build()
        scenario.forwardDrained = false
        scenario.previous = first.summaryDecision
        let during = try scenario.build()
        scenario.forwardDrained = true
        scenario.previous = during.summaryDecision
        // when
        let after = try scenario.build()
        // then
        #expect(during.summaryDecision == first.summaryDecision)
        #expect(after.summaryDecision == first.summaryDecision)
        #expect(after.summaryEntry == first.summaryEntry)
    }

    @Test func givenAShownEntry_whenAnOlderPageIntroducesTextEqualToTheSummary_thenTheEntryStays() throws {
        // given — the older text is not the final message, so it cannot make the summary a duplicate.
        var scenario = SummaryEntryScenario()
        scenario.hasOlder = true
        let before = try scenario.build()
        try #require(before.summaryEntry != nil)
        scenario.previous = before.summaryDecision
        scenario.previousMarkdown = before.markdown
        scenario.items = [SummaryEntryScenario.text(0, summary)] + scenario.items
        // when
        let after = try scenario.build()
        // then
        #expect(after.summaryEntry == before.summaryEntry)
        #expect(after.summaryDecision?.outcome == .shown)
        #expect(after.activityRows.count == 3)
    }

    @Test func givenTheRule_whenEvaluated_thenTheTextIsTheProjectedSummaryOnlyForAShownDecision() throws {
        // given
        let shown = SummaryEntryScenario()
        var suppressed = SummaryEntryScenario()
        suppressed.items = [SummaryEntryScenario.text(1, summary)]
        var reused = SummaryEntryScenario()
        reused.previous = decision(.suppressed)
        reused.forwardDrained = false
        var withheld = SummaryEntryScenario()
        withheld.shows = false
        // when
        let shownResult = TaskDetailSummaryEntryRule.evaluate(shown.input())
        let suppressedResult = TaskDetailSummaryEntryRule.evaluate(suppressed.input())
        let reusedResult = TaskDetailSummaryEntryRule.evaluate(reused.input())
        // then
        #expect(shownResult.decision?.outcome == .shown)
        #expect(shownResult.text == summary)
        #expect(suppressedResult.decision?.outcome == .suppressed)
        #expect(suppressedResult.text == nil)
        #expect(reusedResult.decision == decision(.suppressed))
        #expect(reusedResult.text == nil)
        #expect(TaskDetailSummaryEntryRule.evaluate(withheld.input()).text == nil)
        #expect(TaskDetailSummaryEntryRule.decide(shown.input()) == shownResult.decision)
    }

    @Test func givenAShownDecision_whenTheSummaryChangesFromNFCToNFDBytes_thenTheDecisionIsMadeAgain() throws {
        // given — the two Strings compare equal, their bytes do not.
        let composed = "Caf\u{00E9} fixed."
        let decomposed = "Cafe\u{0301} fixed."
        try #require(composed == decomposed)
        var scenario = SummaryEntryScenario()
        scenario.snapshotSummary = decomposed
        scenario.previous = decision(.shown, raw: composed)
        scenario.items = [SummaryEntryScenario.text(1, decomposed)]
        // when — the fresh decision compares the new bytes with the final message and suppresses.
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryDecision?.rawSummary.utf8.elementsEqual(decomposed.utf8) == true)
        #expect(presentation.summaryDecision?.outcome == .suppressed)
        #expect(presentation.summaryEntry == nil)
    }

    @Test func givenAShownDecision_whenTheSummaryIsByteIdentical_thenTheDecisionIsReused() throws {
        // given
        var scenario = SummaryEntryScenario()
        scenario.previous = decision(.shown)
        scenario.items = [SummaryEntryScenario.text(1, summary)]
        // when
        let presentation = try scenario.build()
        // then
        #expect(presentation.summaryDecision == decision(.shown))
    }
}

// MARK: - TaskReportedSummaryTests

/// The one pure projection shared by the Events tab's Result section and the Summary feed entry.
@Suite struct TaskReportedSummaryTests {
    private func info(_ summary: String? = nil, fields: [String: JSONValue] = [:]) -> TaskInfo {
        SummaryEntryScenario.info(status: "completed", summary: summary, fields: fields)
    }

    @Test func givenASnapshotAndAListing_whenRead_thenTheSnapshotSummaryWins() {
        // given
        let snapshot = info("From the snapshot.")
        let listing = info("From the listing.")
        // when / then
        #expect(TaskReportedSummary.raw(snapshot: snapshot, task: listing) == "From the snapshot.")
    }

    @Test func givenASnapshotWithoutASummary_whenRead_thenTheListingSummaryIsUsed() {
        // given
        let snapshot = info()
        let listing = info("From the listing.")
        // when / then
        #expect(TaskReportedSummary.raw(snapshot: snapshot, task: listing) == "From the listing.")
        #expect(TaskReportedSummary.raw(snapshot: nil, task: listing) == "From the listing.")
    }

    @Test func givenNoSummaryAnywhere_whenRead_thenItIsNil() {
        // given / when / then
        #expect(TaskReportedSummary.raw(snapshot: info(), task: info()) == nil)
        #expect(TaskReportedSummary.raw(snapshot: nil, task: info()) == nil)
    }

    @Test func givenAnOrdinaryTask_whenProjected_thenTheRawTextIsReturnedUntouched() {
        // given
        let raw = "  Keeps its whitespace.\n"
        // when / then
        #expect(TaskReportedSummary.projected(raw: raw, task: info(), isWorkflowBuilder: false) == raw)
        #expect(TaskReportedSummary.projected(raw: nil, task: info(), isWorkflowBuilder: false) == nil)
    }

    @Test func givenAManagedTask_whenProjected_thenTheNodeProjectionApplies() throws {
        // given
        let envelope = #"{"status":"succeeded","result":{"answer":"Done"},"evidence":["checked"]}"#
        let task = info(fields: ["workflow_role": .string("node"), "execution_contract": .string("delegation")])
        // when
        let projected = TaskReportedSummary.projected(raw: envelope, task: task, isWorkflowBuilder: false)
        // then
        #expect(projected == WorkflowNodePresentation.summary(envelope, task: task))
        #expect(projected != envelope)
    }

    @Test func givenAMalformedWorkflowResult_whenProjected_thenTheMalformedOutputTextShows() throws {
        // given
        let task = info(fields: ["workflow_result_error": .string("Missing evidence.")])
        // when
        let projected = try #require(TaskReportedSummary.projected(raw: "prose", task: task, isWorkflowBuilder: false))
        // then
        #expect(projected.hasPrefix("Malformed output"))
        #expect(projected.contains("Missing evidence."))
    }

    @Test func givenAWorkflowBuilder_whenProjected_thenTheBuilderProjectionApplies() {
        // given
        let raw = "Plain builder reply."
        // when / then
        #expect(TaskReportedSummary.projected(raw: raw, task: info(), isWorkflowBuilder: true) == WorkflowBuilderPresentation.summary(raw))
    }
}
