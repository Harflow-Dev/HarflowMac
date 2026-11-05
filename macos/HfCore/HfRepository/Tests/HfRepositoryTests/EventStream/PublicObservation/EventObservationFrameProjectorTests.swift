import Foundation
@testable import HfRepository
import MonitorCore
import Testing

// MARK: - EventObservationFrameProjectorTests

@Suite struct EventObservationFrameProjectorTests {
    @Test func givenPublicCapabilityRefusal_whenProjected_thenActionableReasonSurvivesInAtomicHistory() {
        // given
        var snapshot = makeSnapshot([])
        let failure = ToolError.refused(code: "missing_capability", message: "The selected engine requires task-event-page.v1 support.")
        snapshot.error = failure
        snapshot.issues.insert(.unavailable)
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.history.failure == failure)
        #expect(frame.history.currentness == .reconnecting)
        #expect(frame.records.isEmpty)
    }

    @Test func givenRepeatedRegressingSequences_whenProjected_thenWireOrderAndDistinctOccurrenceIdentitiesSurvive() {
        // given
        let snapshot = makeSnapshot([ObservationFixtures.record(7), ObservationFixtures.record(7), ObservationFixtures.record(6)])
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.records.map(\.record.seq) == [7, 7, 6])
        #expect(frame.events.map(\.seq) == [7, 7, 6])
        #expect(Set(frame.records.map(\.id)).count == 3)
        #expect(Set(frame.items.map(\.id)).count == 3)
        #expect(frame.history.reasons.contains(.ambiguousOrder))
        #expect(frame.summary.counts == nil)
    }

    @Test func givenRetainedOccurrences_whenPrependingAndReplacingWindow_thenPrependKeepsAnchorsAndReplacementChangesCompositeIdentity() {
        // given
        var snapshot = makeSnapshot([ObservationFixtures.record(7), ObservationFixtures.record(8)])
        let original = project(snapshot)
        // when
        let earlier = ObservationFixtures.page([ObservationFixtures.record(6)]).events[0]
        snapshot.activity.insert(.init(epoch: snapshot.windowID, admission: 3, record: earlier), at: 0)
        let prepended = project(snapshot)
        snapshot.windowID = UUID()
        let replaced = project(snapshot)
        // then
        #expect(Array(prepended.records.dropFirst().map(\.id)) == original.records.map(\.id))
        #expect(prepended.scope == original.scope)
        #expect(replaced.scope.sourceID == original.scope.sourceID)
        #expect(replaced.scope.sessionID == original.scope.sessionID)
        #expect(Set(replaced.records.map(\.id)).isDisjoint(with: Set(prepended.records.map(\.id))))
        #expect(replaced.scope.identity != original.scope.identity)
    }

    @Test func givenUnsupportedMissingAndTruncatedPayloads_whenProjected_thenRawEvidenceSurvivesWithoutFabricatedSuccessfulOutput() {
        // given
        let malformedResult = ObservationFixtures.record(2, "tool_result", ["call_id": .string("edit")])
        let truncatedResult = ObservationFixtures.record(3, "tool_result", ["call_id": .string("edit"), "truncated": .bool(true)])
        let unknown = ObservationFixtures.record(4, "future_kind", ["additive": .string(" retained \n🙂\t")])
        let snapshot = makeSnapshot([ObservationFixtures.call(1, id: "edit", path: "file"), malformedResult, truncatedResult, unknown])
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.records.map(\.record.raw) == snapshot.activity.map(\.record.raw))
        #expect(frame.records.count == 4)
        let normalizedBytes = frame.records.last?.normalizedJSON.data(using: .utf8)
        let copiedRecord = normalizedBytes.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        #expect(copiedRecord == .object(unknown))
        #expect(frame.events.count == 1)
        #expect(frame.items.count == 1)
        #expect(frame.items.first?.isRunningTool == true)
        #expect(frame.history.reasons.isSuperset(of: [.unsupportedPayload, .normalizationLoss, .unknownKind]))
        #expect(frame.summary.counts == nil)
    }

    @Test(arguments: [false, true])
    func givenKnownLossBetweenContiguousRecords_whenProjected_thenToolResultsAndTextCannotJoinAcrossUncertainBoundary(pageLoss: Bool) {
        // given
        let delta = ObservationFixtures.record(3, "assistant_delta", ["text": .string("partial"), "message_id": .string("message"), "block_index": .number(0)])
        let final = ObservationFixtures.record(4, "assistant_text", ["text": .string("final"), "message_id": .string("message"), "block_index": .number(0)])
        var raw = [ObservationFixtures.call(1, id: "edit", path: "file"), ObservationFixtures.result(2, id: "edit", ok: true), delta, final]
        if !pageLoss {
            raw.insert(ObservationFixtures.record(2, "future_kind"), at: 1)
            raw.insert(ObservationFixtures.record(4, "future_kind"), at: 4)
        }
        var snapshot = makeSnapshot(raw)
        if pageLoss { snapshot.coverage.malformed = 1 }
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.items.first?.isRunningTool == true)
        #expect(frame.items.count == 3)
        #expect(frame.events.count == 4)
        #expect(frame.history.reasons.contains(pageLoss ? .skippedRecords : .unknownKind))
    }

    @Test func givenContinuousSoundRecords_whenProjected_thenKnownPairingStillWorks() {
        // given
        let snapshot = makeSnapshot([ObservationFixtures.call(1, id: "edit", path: "file"), ObservationFixtures.result(2, id: "edit", ok: true)])
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.items.count == 1)
        guard case .tool(_, let result) = frame.items.first?.body else {
            Issue.record("Expected the captured tool call")
            return
        }
        #expect(result?.ok == true)
        #expect(result?.outputTail == "done")
    }

    @Test func givenActivityCapacityWithQualifiedSummary_whenProjected_thenWindowReasonDoesNotEraseObservedTotals() {
        // given
        var snapshot = makeSnapshot([ObservationFixtures.call(1, id: "edit", path: "file")])
        var counts = ActivityCounts()
        counts.toolCalls = 1
        counts.edits = 1
        snapshot.summary = PublicEventSummary(state: .observed, counts: counts,
            files: [EditedFile(path: "file", status: .edited)], totalFiles: 1, issues: [])
        snapshot.issues.insert(.capacity)
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.history.reasons.contains(.capacity))
        #expect(frame.history.availableActions.contains(.rebaseWindow))
        #expect(frame.summary.state == .observed)
        #expect(frame.summary.counts == counts)
        #expect(frame.summary.totalFiles == 1)
        #expect(frame.summary.reasons.isEmpty)
    }

    @Test func givenAllSummaryQualifications_whenProjected_thenEveryReasonSurvivesAndUnknownTotalsRemainAbsent() {
        // given
        let reasons: Set<PublicEventSummaryIssue> = [.normalizationLoss, .skippedRecords, .gaps, .captureUnavailable,
            .unknownKind, .unsupportedPayload, .ambiguousOrder, .ambiguousCall, .capacity, .historicalLimit, .nonprogress, .requestUnavailable]
        let expected: Set<EventObservationReason> = [.normalizationLoss, .skippedRecords, .gaps, .captureUnavailable,
            .unknownKind, .unsupportedPayload, .ambiguousOrder, .ambiguousCall, .capacity, .historicalLimit, .nonprogress, .requestUnavailable]
        var snapshot = makeSnapshot([])
        snapshot.summary = PublicEventSummary(state: .unavailable, counts: nil, files: [], totalFiles: nil, issues: reasons)
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.summary.reasons == expected)
        #expect(frame.summary.state == .unavailable)
        #expect(frame.summary.counts == nil)
        #expect(frame.summary.totalFiles == nil)
        #expect(frame.summary.files.isEmpty)
    }

    @Test func givenNonadjacentPublicSequencesWithoutReportedGap_whenProjected_thenSequenceArithmeticDoesNotInventCaptureLoss() {
        // given
        let snapshot = makeSnapshot([ObservationFixtures.record(1), ObservationFixtures.record(3)])
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.records.map(\.record.seq) == [1, 3])
        #expect(!frame.history.reasons.contains(.gaps))
    }

    @Test(arguments: [ObservedActivitySummary.State.loading, .unavailable, .limited])
    func givenUnqualifiedSummaryWithPartialValues_whenConstructed_thenValuesAreWithheldRatherThanPresentedAsZero(state: ObservedActivitySummary.State) {
        // given
        var partial = ActivityCounts()
        partial.toolCalls = 12
        // when
        let summary = ObservedActivitySummary(state: state, counts: partial,
            files: [EditedFile(path: "partial", status: .edited)], totalFiles: 1, reasons: [.gaps])
        // then
        #expect(summary.counts == nil)
        #expect(summary.totalFiles == nil)
        #expect(summary.files.isEmpty)
        #expect(summary.reasons == [.gaps])
    }

    @Test func givenSourceChangeAtHistoricalBudgetCeiling_whenProjected_thenNoAdoptionActionIsOffered() {
        // given
        var snapshot = makeSnapshot([ObservationFixtures.record(1)])
        snapshot.sourceChangePending = true
        snapshot.historicalOperations = 4096
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.history.currentness == .sourceChangePending)
        #expect(!frame.history.availableActions.contains(.adoptCurrentSource))
        #expect(frame.records.count == 1)
    }

    @Test func givenCapturedDisplayPrompt_whenProjected_thenStoredRequestRemainsIndependentlyNotRequested() {
        // given
        let snapshot = makeSnapshot([ObservationFixtures.record(1, "task_started", ["prompt": .string("display preview")])])
        // when
        let frame = project(snapshot)
        // then
        #expect(frame.events.count == 1)
        #expect(snapshot.prompt == .notRequested)
        #expect(frame.summary.counts == nil)
    }

    private func makeSnapshot(_ raw: [[String: JSONValue]]) -> PublicEventObservationSnapshot {
        var snapshot = PublicEventObservationSnapshot(sessionID: UUID())
        snapshot.activity = ObservationFixtures.page(raw).events.enumerated().map {
            .init(epoch: snapshot.windowID, admission: $0.offset + 1, record: $0.element)
        }
        return snapshot
    }

    private func project(_ snapshot: PublicEventObservationSnapshot) -> EventObservationFrame {
        EventObservationFrameProjector.project(taskID: "task", snapshot: snapshot)
    }
}
