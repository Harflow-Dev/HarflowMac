import Foundation
@testable import HfRepository
@testable import MainWindowFeature
@testable import MonitorCore
import Testing

// MARK: - Fixtures

enum StopFixture {
    static let id = "20261110-093000-a17c92"
    static let generation = String(repeating: "a", count: 32)
    static let otherGeneration = String(repeating: "b", count: 32)
    static let runtime = QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))

    static func receipt(
        taskID: String = id, state: String = "stopped", basis: String = "proven_not_started",
        coverage: String = "complete", truncated: Bool = false
    ) -> TaskPendingLaunchStopReceipt {
        let observation: [String: JSONValue] = [
            "scope": .string("recorded_tasks_and_pending_launches"), "observed_at": .string("2026-11-11T00:00:00+00:00"),
            "coverage": .string(coverage), "truncated": .bool(truncated),
            "items": .array([.object(["task_id": .string(taskID), "state": .string(state), "basis": .string(basis),
                                      "status": .string("cancelled")])])
        ]
        let raw: [String: JSONValue] = ["task_id": .string(taskID), "status": .string("cancelled"),
                                        "cascade": .object(["observation": .object(observation)])]
        return TaskPendingLaunchStopReceipt(raw: raw, matching: TaskPendingLaunchStopRequest(taskID: taskID)!)!
    }

    static func confirmation(taskID: String = id, generation: String = generation) -> PendingLaunchStopConfirmation {
        PendingLaunchStopConfirmation(id: UUID(), taskID: taskID, generation: generation, runtime: runtime, epoch: UUID())
    }

    static func attempt(
        executing: Bool = false, failure: PendingLaunchFailure? = nil, outcome: TaskPendingLaunchStopOutcome? = nil,
        taskID: String = id, generation: String = generation
    ) -> PendingLaunchStopAttempt {
        PendingLaunchStopAttempt(id: UUID(), confirmation: confirmation(taskID: taskID, generation: generation), isExecuting: executing,
                                 preflightFailure: failure, outcome: outcome)
    }

    static let request = TaskPendingLaunchStopRequest(taskID: id)!

    static func evidence(
        _ phase: PendingLaunchStopEvidence.Phase, generation: String = generation, taskID: String = id
    ) -> PendingLaunchStopEvidence {
        PendingLaunchStopEvidence(attemptID: UUID(), taskID: taskID, generation: generation, phase: phase)
    }

    static func projection(_ values: [PendingLaunchStopEvidence]) -> PendingLaunchStopProjection? {
        PendingLaunchStopProjection(values, taskID: id)
    }
}

// MARK: - PendingLaunchStopPresentationTests

@Suite struct PendingLaunchStopPresentationTests {
    private typealias Fixture = StopFixture
    private let id = StopFixture.id
    private let settled = PendingLaunchDetailFlags(firstCheckSettled: true)
    private let utc = TimeZone(identifier: "UTC")!

    private func detail(
        _ item: TaskPendingLaunchItem? = nil, stop: [PendingLaunchStopEvidence] = [], runtimeKnown: Bool = true,
        flags: PendingLaunchDetailFlags? = nil
    ) -> PendingLaunchDetailPresentation {
        let item = item ?? PendingLaunchesFixture.item(id: id)
        return .make(taskID: id, evidence: .value(PendingLaunchesFixture.lookup(item)), flags: flags ?? settled,
                     stop: Fixture.projection(stop), runtimeKnown: runtimeKnown, timeZone: utc)
    }

    private func plain(_ disposition: String, stop: [PendingLaunchStopEvidence] = [], flags: PendingLaunchDetailFlags? = nil)
        -> PendingLaunchDetailPresentation {
        .make(taskID: id, evidence: .value(PendingLaunchesFixture.plainLookup(id: id, disposition: disposition)), flags: flags ?? settled,
              stop: Fixture.projection(stop), runtimeKnown: true, timeZone: utc)
    }

    private var unconfirmed: String { PendingLaunchDetailPresentation.unconfirmedNote }
    private var availability: String { PendingLaunchDetailPresentation.availabilityNote }
    private var notSent: String { PendingLaunchDetailPresentation.notSentNote }

    // MARK: - Classification

    @Test func givenEveryAttemptShape_whenClassified_thenPhaseAndSafety() throws {
        // given
        let engine = ConversationDeliveryEngineError(code: "invalid_params", message: "refused", data: nil)
        let cases: [(PendingLaunchStopAttempt, PendingLaunchStopEvidence.Phase, Bool)] = [
            (Fixture.attempt(executing: true), .sending, true),
            (Fixture.attempt(failure: .changed), .preflightChanged, false),
            (Fixture.attempt(failure: .recorded), .preflightChanged, false),
            (Fixture.attempt(failure: .busy), .notSent, false),
            (Fixture.attempt(failure: .tool(.refused(code: "x", message: "y"))), .notSent, false),
            (Fixture.attempt(outcome: .notDispatched(Fixture.request, cause: .missingCapability("x"))), .notSent, false),
            (Fixture.attempt(outcome: .accepted(Fixture.receipt())), .didNotStart, true),
            (Fixture.attempt(outcome: .accepted(Fixture.receipt(basis: "observed_settlement"))), .requested, true),
            (Fixture.attempt(outcome: .accepted(Fixture.receipt(coverage: "incomplete"))), .requested, true),
            (Fixture.attempt(outcome: .accepted(Fixture.receipt(truncated: true))), .requested, true),
            (Fixture.attempt(outcome: .uncertain(Fixture.request, cause: .receiptIdentityMismatch)), .uncertain, true),
            (Fixture.attempt(outcome: .uncertain(Fixture.request, cause: .timedOut(seconds: 300))), .uncertain, true),
            (Fixture.attempt(outcome: .engineError(Fixture.request, engine)), .refused(reason: "refused"), true),
            // Not executing with no failure and no outcome cannot happen; it is treated as unsafe and unknown.
            (Fixture.attempt(), .uncertain, true)
        ]
        for (attempt, phase, unsafe) in cases {
            // when
            let evidence = PendingLaunchStopEvidence(attempt)
            // then
            #expect(evidence.phase == phase, "\(phase)")
            #expect(evidence.isUnsafe == unsafe, "\(phase)")
            #expect(evidence.taskID == id && evidence.generation == Fixture.generation && evidence.attemptID == attempt.id)
        }
    }

    // MARK: - Reason

    @Test func givenEngineMessages_whenNormalized_thenCollapsedEscapedAndCapped() {
        // given / when / then
        #expect(PendingLaunchStopEvidence.reason(from: "refused by workflow") == "refused by workflow")
        #expect(PendingLaunchStopEvidence.reason(from: "  \n\t ") == nil)
        #expect(PendingLaunchStopEvidence.reason(from: "") == nil)
        #expect(PendingLaunchStopEvidence.reason(from: " one\ntwo\t\tthree \r\n four ") == "one two three four")
        #expect(PendingLaunchStopEvidence.reason(from: "a\u{202E}b\u{0007}c") == "a\\u{202E}b\\x07c")
        let long = PendingLaunchStopEvidence.reason(from: String(repeating: "x", count: 5000))
        #expect(long == String(repeating: "x", count: 1024) + "…")
    }

    @Test func givenReasonThatEndsWithPeriod_whenRefusedCardShown_thenPeriodIsNotDoubled() {
        // given
        let withPeriod = Fixture.evidence(.refused(reason: "Not allowed."))
        let plainReason = Fixture.evidence(.refused(reason: "Not allowed"))
        let blank = Fixture.evidence(.refused(reason: nil))
        // when
        let cards = [withPeriod, plainReason, blank].map { detail(stop: [$0]) }
        // then
        let generic = "The engine refused Stop. The launch or task may still be active."
        #expect(cards[0].message == generic + " Reason: Not allowed.")
        #expect(cards[1].message == generic + " Reason: Not allowed.")
        #expect(cards[2].message == generic)
        #expect(cards.allSatisfy { $0.kind == .stopRefused && $0.title == "Stop refused" && $0.notes.isEmpty })
    }

    @Test func givenFailedPreparationRead_whenStatusIsUnavailable_thenNotSentLineShowsWithoutAStopButton() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, stopPrepareNotSent: true)
        // when
        let card = PendingLaunchDetailPresentation.make(taskID: id, evidence: .failed, flags: flags, runtimeKnown: true)
        // then
        #expect(card.kind == .unavailable && card.title == "Launch status unavailable")
        #expect(card.stop == nil)
        #expect(card.notes == [notSent])
    }

    @Test func givenCappedReasonEndingInEllipsis_whenCardShown_thenNoPeriodIsAppended() {
        // given
        let reason = PendingLaunchStopEvidence.reason(from: String(repeating: "x", count: 3000))
        // when
        let card = detail(stop: [Fixture.evidence(.refused(reason: reason))])
        // then
        #expect(card.message.hasSuffix("…"))
        #expect(!card.message.hasSuffix("…."))
    }

    // MARK: - Eligibility

    @Test(arguments: [("waiting_for_resources", true), ("reserved", true), ("claimed", true), ("granted", true), ("not_started", false)])
    func givenStateAndSupport_whenEligibilityComputed_thenOnlySupportedLiveStatesQualify(state: String, live: Bool) {
        // given
        for support in ["supported", "unsupported", "future"] {
            let item = PendingLaunchesFixture.item(id: id, state: state, cancelSupport: support)
            // when
            let eligible = PendingLaunchDetailPresentation.stopEligibility(item: item, runtimeKnown: true)
            // then
            #expect(eligible == (live && support == "supported"), "\(state) \(support)")
            #expect(!PendingLaunchDetailPresentation.stopEligibility(item: item, runtimeKnown: false))
        }
    }

    @Test func givenNonPendingDispositions_whenEligibilityComputed_thenNever() {
        for disposition in ["recorded", "not_found", "refused", "unknown"] {
            let item = PendingLaunchesFixture.plainLookup(id: id, disposition: disposition).item
            #expect(!PendingLaunchDetailPresentation.stopEligibility(item: item, runtimeKnown: true), "\(disposition)")
        }
    }

    @Test func givenEligibleLaunch_whenMapped_thenStopWithAvailabilityNote() {
        // given / when
        let shown = detail()
        let hiddenRuntime = detail(runtimeKnown: false)
        let busy = detail(flags: .init(firstCheckSettled: true, isBusy: true))
        let handshake = detail(PendingLaunchesFixture.item(id: id, state: "claimed", cancelSupport: "unsupported"))
        let unrecognized = detail(PendingLaunchesFixture.item(id: id, cancelSupport: "future"))
        let notStarted = detail(PendingLaunchesFixture.item(id: id, state: "not_started"))
        // then
        #expect(shown.stop == .enabled && shown.notes == [availability])
        #expect(hiddenRuntime.stop == nil && hiddenRuntime.notes.isEmpty)
        #expect(busy.stop == .disabled && busy.notes == [availability])
        for hidden in [handshake, unrecognized, notStarted] {
            #expect(hidden.stop == nil && hidden.notes.isEmpty)
        }
    }

    @Test func givenRuntimeBecomesKnown_whenMappedAgain_thenStopAppears() {
        #expect(detail(runtimeKnown: false).stop == nil)
        #expect(detail(runtimeKnown: true).stop == .enabled)
    }

    @Test func givenSendingAttempt_whenMapped_thenCurrentCardWithStopDisabledAndNoNewCopy() {
        // given / when
        let sending = detail(stop: [Fixture.evidence(.sending)])
        // then
        #expect(sending.kind == .waiting && sending.title == "Waiting for resources")
        #expect(sending.stop == .disabled)
        #expect(sending.notes == [availability])
    }

    @Test func givenUnsafeGeneration_whenLaunchIsEligible_thenStopHiddenForThatGenerationOnly() {
        // given: an earlier attempt on the old generation, and a lookup now showing a new generation.
        var raw = PendingLaunchesFixture.item(id: id).raw
        var launch = raw["launch"]!.objectValue!
        launch["generation"] = .string(Fixture.otherGeneration)
        raw["launch"] = .object(launch)
        let newGeneration = TaskPendingLaunchItem(raw: raw)!
        let oldAttempt = Fixture.evidence(.requested)
        // when
        let same = detail(stop: [oldAttempt], flags: .init(firstCheckSettled: true, acknowledgedAttempt: true))
        let next = detail(newGeneration, stop: [oldAttempt])
        // then
        #expect(same.stop == nil && same.notes == [unconfirmed])
        #expect(next.kind == .waiting && next.stop == .enabled)
        #expect(next.notes == [availability])
    }

    // MARK: - Outcome cards

    @Test func givenResolvedAttempts_whenMapped_thenExactOutcomeCards() {
        // given
        let cases: [(PendingLaunchStopEvidence.Phase, PendingLaunchDetailPresentation.Kind, String, String, [String])] = [
            (.requested, .stopRequested, "Stop requested",
             "The request was accepted. This does not confirm that the launch or task stopped. Check its status again.", [unconfirmed]),
            (.uncertain, .stopUncertain, "Stop outcome unknown",
             "The Stop response could not be confirmed. The launch or task may still be active. Check its state before taking another action.",
             [unconfirmed]),
            (.refused(reason: nil), .stopRefused, "Stop refused",
             "The engine refused Stop. The launch or task may still be active.", []),
            (.didNotStart, .stopDidNotStart, "Did not start", "The engine recorded that this launch did not start.", [])
        ]
        for (phase, kind, title, message, notes) in cases {
            // when
            let card = detail(stop: [Fixture.evidence(phase)])
            // then
            #expect(card.kind == kind)
            #expect(card.title == title)
            #expect(card.message == message)
            #expect(card.notes == notes)
            #expect(card.action == .checkAgain && card.isActionEnabled && card.stop == nil)
            #expect(card.facts.first?.label == "Launch ID")
        }
        #expect(unconfirmed == "Harflow will not send Stop again automatically. A missing launch or an unavailable status does not confirm that it stopped.")
    }

    @Test func givenOutcomeWithoutPendingLookup_whenMapped_thenSelectedIDFactAndItWinsOverThePlaceholder() {
        // given
        let stop = Fixture.projection([Fixture.evidence(.requested)])
        // when
        let placeholder = PendingLaunchDetailPresentation.make(taskID: id, evidence: .none, flags: .init(), stop: stop, runtimeKnown: true)
        let recorded = plain("recorded", stop: [Fixture.evidence(.requested)])
        // then
        #expect(placeholder.kind == .stopRequested)
        #expect(placeholder.facts.map(\.label) == ["Selected ID"])
        #expect(recorded.kind == .stopRequested && recorded.facts.map(\.label) == ["Selected ID"])
    }

    @Test func givenAcknowledgedOutcome_whenMapped_thenStatusReturnsAndTheCheckingPlaceholderShowsNoStopCopy() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, acknowledgedAttempt: true)
        let stop = Fixture.projection([Fixture.evidence(.requested)])
        // when
        let status = detail(stop: [Fixture.evidence(.requested)], flags: flags)
        let checking = PendingLaunchDetailPresentation.make(
            taskID: id, evidence: .none, flags: .init(acknowledgedAttempt: true), stop: stop, runtimeKnown: true
        )
        // then
        #expect(status.kind == .waiting && status.stop == nil && status.notes == [unconfirmed])
        #expect(checking.kind == .checking && checking.notes.isEmpty && checking.stop == nil)
    }

    @Test func givenAcknowledgedRefusalOnEligibleLaunch_whenMapped_thenStopStaysHiddenWithNoNote() {
        // given / when
        let status = detail(stop: [Fixture.evidence(.refused(reason: "no"))], flags: .init(firstCheckSettled: true, acknowledgedAttempt: true))
        // then
        #expect(status.kind == .waiting)
        #expect(status.stop == nil)
        #expect(status.notes.isEmpty)
    }

    @Test func givenLookupWithAnotherGeneration_whenOutcomeExists_thenNoCard() {
        // given
        var raw = PendingLaunchesFixture.item(id: id).raw
        var launch = raw["launch"]!.objectValue!
        launch["generation"] = .string(Fixture.otherGeneration)
        raw["launch"] = .object(launch)
        // when
        let card = detail(TaskPendingLaunchItem(raw: raw)!, stop: [Fixture.evidence(.requested)])
        // then
        #expect(card.kind == .waiting)
    }

    @Test func givenOutcomeCard_whenLookupIsPending_thenQualifiedFactsElseSelectedID() {
        // given / when
        let qualified = detail(stop: [Fixture.evidence(.uncertain)])
        let bare = plain("not_found", stop: [Fixture.evidence(.uncertain)])
        // then
        #expect(qualified.facts.map(\.label) == ["Launch ID", "Harness", "Repository", "Created", "Resources"])
        #expect(bare.facts.map(\.label) == ["Selected ID"])
    }

    @Test func givenBusy_whenOutcomeCardShown_thenCheckAgainIsDisabled() {
        #expect(!detail(stop: [Fixture.evidence(.requested)], flags: .init(firstCheckSettled: true, isBusy: true)).isActionEnabled)
    }

    // MARK: - Notes

    @Test func givenUnconfirmedAttempt_whenStatusCardsAreMapped_thenNoteOnEveryCardOfTheID() {
        // given: acknowledged so the status cards show.
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, acknowledgedAttempt: true)
        let attempt = [Fixture.evidence(.uncertain)]
        // when
        let cards = [
            detail(PendingLaunchesFixture.item(id: id, state: "claimed", cancelSupport: "unsupported"), stop: attempt, flags: flags),
            detail(PendingLaunchesFixture.item(id: id, state: "not_started"), stop: attempt, flags: flags),
            plain("not_found", stop: attempt, flags: flags),
            plain("recorded", stop: attempt, flags: flags),
            .make(taskID: id, evidence: .failed, flags: flags, stop: Fixture.projection(attempt), runtimeKnown: true),
            .make(taskID: id, evidence: .failed, flags: .init(firstCheckSettled: true, handoffFailed: true, acknowledgedAttempt: true),
                  stop: Fixture.projection(attempt), runtimeKnown: true)
        ]
        // then
        for card in cards { #expect(card.notes.contains(unconfirmed), "\(card.kind)") }
        #expect(cards.map(\.kind) == [.preparingHandshake, .notStarted, .missing, .recorded, .unavailable, .unavailable])
    }

    @Test func givenHandoffFailedRecorded_whenUnconfirmedAttemptExists_thenNoteShows() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, handoffFailed: true, acknowledgedAttempt: true)
        // when
        let card = plain("recorded", stop: [Fixture.evidence(.requested)], flags: flags)
        // then
        #expect(card.kind == .handoffFailed && card.notes == [unconfirmed])
    }

    @Test func givenRefusedOrNotSentOnly_whenStatusMapped_thenNoUnconfirmedNote() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, acknowledgedAttempt: true, notSentCleared: true)
        // when
        let refused = plain("not_found", stop: [Fixture.evidence(.refused(reason: nil))], flags: flags)
        let notSentOnly = plain("not_found", stop: [Fixture.evidence(.notSent)], flags: flags)
        // then
        #expect(refused.notes.isEmpty)
        #expect(notSentOnly.notes.isEmpty)
    }

    @Test func givenNewGenerationEligibleCard_whenOlderGenerationWasUnconfirmed_thenNoNoteAndStopEnabled() {
        // given
        var raw = PendingLaunchesFixture.item(id: id).raw
        var launch = raw["launch"]!.objectValue!
        launch["generation"] = .string(Fixture.otherGeneration)
        raw["launch"] = .object(launch)
        // when
        let card = detail(TaskPendingLaunchItem(raw: raw)!, stop: [Fixture.evidence(.requested)])
        // then
        #expect(card.stop == .enabled)
        #expect(!card.notes.contains(unconfirmed))
    }

    @Test func givenNotSentAttempt_whenMapped_thenLineFirstOnlyForTheSameGenerationAndUntilCleared() {
        // given
        var raw = PendingLaunchesFixture.item(id: id).raw
        var launch = raw["launch"]!.objectValue!
        launch["generation"] = .string(Fixture.otherGeneration)
        raw["launch"] = .object(launch)
        let attempt = [Fixture.evidence(.notSent)]
        // when
        let same = detail(stop: attempt)
        let otherGeneration = detail(TaskPendingLaunchItem(raw: raw)!, stop: attempt)
        let cleared = detail(stop: attempt, flags: .init(firstCheckSettled: true, notSentCleared: true))
        let prepare = detail(flags: .init(firstCheckSettled: true, stopPrepareNotSent: true))
        let prepareAfterClear = detail(flags: .init(firstCheckSettled: true, stopPrepareNotSent: false, notSentCleared: true))
        // then
        #expect(same.stop == .enabled && same.notes == [notSent, availability])
        #expect(otherGeneration.notes == [availability])
        #expect(cleared.notes == [availability])
        #expect(prepare.notes == [notSent, availability])
        #expect(prepareAfterClear.notes == [availability])
    }

    @Test func givenPreflightChanged_whenMapped_thenFreshStatusWithStopAvailable() {
        // given / when
        let card = detail(stop: [Fixture.evidence(.preflightChanged)])
        let recorded = plain("recorded", stop: [Fixture.evidence(.preflightChanged)])
        // then
        #expect(card.kind == .waiting && card.stop == .enabled && card.notes == [availability])
        #expect(recorded.kind == .recorded && recorded.notes.isEmpty)
    }

    @Test func givenNoteOrder_whenNotSentAndUnconfirmedAndAvailabilityApply_thenOrdered() {
        // given: a new generation shows Stop and the not-sent line; its old generation's unconfirmed attempt is elsewhere.
        var raw = PendingLaunchesFixture.item(id: id).raw
        var launch = raw["launch"]!.objectValue!
        launch["generation"] = .string(Fixture.otherGeneration)
        raw["launch"] = .object(launch)
        let newGeneration = TaskPendingLaunchItem(raw: raw)!
        let attempts = [Fixture.evidence(.requested), Fixture.evidence(.notSent, generation: Fixture.otherGeneration)]
        // when
        let card = detail(newGeneration, stop: attempts)
        // then
        #expect(card.notes == [notSent, availability])
    }
}
