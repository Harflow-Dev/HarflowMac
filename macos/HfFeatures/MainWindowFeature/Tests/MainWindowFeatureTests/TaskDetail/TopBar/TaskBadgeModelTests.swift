//
//  TaskBadgeModelTests.swift
//  MainWindowFeatureTests
//

import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - TaskBadgeModelTests

/// The top bar badge as a pure function of `TaskSnapshotEvidence`: a qualifier or a settled duration is claimed only
/// from the matching snapshot, and the precedence is taken over, owner warnings, exit qualifiers, plain status.
@MainActor
@Suite struct TaskBadgeModelTests {
    typealias Model = TaskBadgeModel

    private nonisolated static let started = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let terminal: [TaskStatus] = [.completed, .failed, .timedOut, .cancelled]
    private nonisolated static let everyKnownStatus: [TaskStatus] = [.running] + terminal
    private nonisolated static let otherStatuses: [TaskStatus] = [
        .other("settling"), .other("needs input"), .other("needs attention"), .other("pending"), .other("queued"), .other("novel_state")
    ]

    private func evidence(_ status: TaskStatus, matching: Bool = true, takenOver: Bool = false, exit: Int? = nil,
                          logState: EventLogState? = nil, owner: String? = nil, duration: TimeInterval? = nil) -> TaskSnapshotEvidence {
        TaskSnapshotEvidence(status: status, takenOver: takenOver, snapshotStatus: matching ? status : nil, exitCode: exit,
                             logState: logState, ownerState: matching ? owner : nil, settledDuration: matching ? duration : nil)
    }

    private func make(_ evidence: TaskSnapshotEvidence, startedAt: Date? = nil) -> Model {
        Model.make(evidence: evidence, startedAt: startedAt)
    }

    // MARK: - Plain statuses

    @Test func givenRunning_whenStartIsKnown_thenTheBadgeIsASpinnerWithALiveClock() {
        // given
        let evidence = evidence(.running, matching: false)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .spinner, tone: .running, label: "Running", clock: .live(Self.started), suffix: nil))
    }

    @Test(arguments: [true, false])
    func givenRunning_whenStartIsUnknown_thenThereIsNoClock(matching: Bool) {
        // given / when
        let badge = make(evidence(.running, matching: matching))

        // then
        #expect(badge.clock == .none)
        #expect(badge.label == "Running")
    }

    @Test func givenRunningWithAMatchingSnapshot_whenOwnerStateIsAlive_thenItIsPlainRunning() {
        // given / when
        let badge = make(evidence(.running, owner: "alive"), startedAt: Self.started)

        // then
        #expect(badge.label == "Running")
        #expect(badge.tone == .running)
    }

    @Test(arguments: [
        (TaskStatus.completed, "Done", Model.Icon.symbol("checkmark"), Model.Tone.done),
        (.failed, "Failed", .symbol("xmark"), .failed),
        (.timedOut, "Timed out", .symbol("clock"), .failed),
        (.cancelled, "Cancelled", .symbol("stop.fill"), .neutral)
    ])
    func givenEachSettledStatus_whenItsExitWasObservedWithADuration_thenTheBadgeCarriesTheFixedDuration(
        status: TaskStatus, label: String, icon: Model.Icon, tone: Model.Tone
    ) {
        // given
        let evidence = evidence(status, exit: 0, duration: 271)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge == Model(icon: icon, tone: tone, label: label, clock: .fixed(271), suffix: nil))
    }

    @Test(arguments: terminal)
    func givenEachSettledStatus_whenThereIsNoMatchingSnapshot_thenThereIsNoClockAndNoQualifier(status: TaskStatus) {
        // given a listing row only: even a duration the caller might hold is never shown
        let evidence = TaskSnapshotEvidence(status: status, takenOver: false, snapshotStatus: nil, exitCode: nil,
                                            logState: .incomplete, ownerState: nil, settledDuration: nil)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge.clock == .none)
        #expect(badge.suffix == nil)
        #expect(badge.label == status.label)
    }

    @Test(arguments: terminal)
    func givenEachSettledStatus_whenTheSnapshotIsForAnotherStatus_thenItIsTreatedAsMissing(status: TaskStatus) {
        // given a stale running snapshot beside a settled listing row
        let evidence = TaskSnapshotEvidence(status: status, takenOver: false, snapshotStatus: .running, exitCode: nil,
                                            logState: .incomplete, ownerState: nil, settledDuration: nil)

        // when
        let badge = make(evidence)

        // then
        #expect(badge.label == status.label)
        #expect(badge.clock == .none)
    }

    @Test(arguments: terminal)
    func givenEachSettledStatus_whenNoDurationWasRecorded_thenTheClockIsAbsent(status: TaskStatus) {
        // given / when
        let badge = make(evidence(status, exit: 1, duration: nil))

        // then
        #expect(badge.clock == .none)
    }

    // MARK: - Settled duration

    /// The evidence the VM builds from a listing row and an optional status snapshot.
    private func loadedEvidence(listing: TaskInfo, snapshot: TaskInfo?) async -> TaskSnapshotEvidence? {
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        harness.detailBox.value = listing
        harness.snapshotBox.value = snapshot
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.tasksSubject.send([listing])
        await waitUntil { harness.sut.inspectorModel != nil }
        return harness.sut.snapshotEvidence
    }

    private func info(_ status: String, exit: Int? = nil, duration: Double? = nil, owner: String? = nil) -> TaskInfo {
        var raw: [String: JSONValue] = ["task_id": .string("abc12345"), "backend": .string("claude"), "status": .string(status)]
        if let exit { raw["exit_code"] = .number(Double(exit)) }
        if let duration { raw["duration_seconds"] = .number(duration) }
        if let owner { raw["supervision"] = .object(["owner_state": .string(owner)]) }
        return TaskInfo(.object(raw))!
    }

    @Test func givenAnObservedExitAndARecordedDuration_whenEvidenceIsBuilt_thenTheDurationIsTheSettledDuration() async {
        // given
        let snapshot = info("completed", exit: 0, duration: 271)

        // when
        let evidence = await loadedEvidence(listing: snapshot, snapshot: snapshot)

        // then
        #expect(evidence?.settledDuration == 271)
        #expect(evidence?.exitCode == 0)
    }

    @Test func givenARecordedDurationWithoutAnObservedExit_whenEvidenceIsBuilt_thenThereIsNoSettledDuration() async {
        // given
        let snapshot = info("cancelled", duration: 271)

        // when
        let evidence = await loadedEvidence(listing: snapshot, snapshot: snapshot)

        // then the C6 rule: a cancelled task without an observed exit shows no duration
        #expect(evidence?.settledDuration == nil)
        let clock = evidence.map { Model.make(evidence: $0, startedAt: nil).clock }
        #expect(clock == Model.Clock.none)
    }

    @Test func givenAMissingSnapshot_whenEvidenceIsBuilt_thenOwnerStateAndDurationAreNil() async {
        // given a listing row that claims an exit, a duration and a dead owner
        let listing = info("completed", exit: 0, duration: 271, owner: "dead")

        // when
        let evidence = await loadedEvidence(listing: listing, snapshot: nil)

        // then the listing row never supports a duration or an owner claim
        #expect(evidence?.snapshotStatus == nil)
        #expect(evidence?.ownerState == nil)
        #expect(evidence?.settledDuration == nil)
    }

    @Test func givenASnapshotOfAnotherStatus_whenEvidenceIsBuilt_thenOwnerStateAndDurationAreNil() async {
        // given a running snapshot behind a completed listing row
        let listing = info("completed", exit: 0, duration: 271)
        let stale = info("running", exit: 0, duration: 12, owner: "dead")

        // when
        let evidence = await loadedEvidence(listing: listing, snapshot: stale)

        // then
        #expect(evidence?.snapshotStatus == .running)
        #expect(evidence?.hasMatchingSnapshot == false)
        #expect(evidence?.ownerState == nil)
        #expect(evidence?.settledDuration == nil)
    }

    @Test func givenAMatchingSnapshot_whenItReportsAnOwnerState_thenEvidenceCarriesIt() async {
        // given
        let running = info("running", owner: "undecidable")

        // when
        let evidence = await loadedEvidence(listing: running, snapshot: running)

        // then
        #expect(evidence?.ownerState == "undecidable")
    }

    // MARK: - Owner warnings

    @Test func givenRunningWithADeadOwner_whenMatchingEvidenceExists_thenTheBadgeWarnsOwnerLostWithoutAClock() {
        // given / when
        let badge = make(evidence(.running, owner: "dead"), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .symbol("exclamationmark.triangle.fill"), tone: .warning,
                               label: "Running · owner lost", clock: .none, suffix: nil))
    }

    @Test func givenRunningWithAnUndecidableOwner_whenMatchingEvidenceExists_thenTheBadgeWarnsNotVerifiedWithoutAClock() {
        // given / when
        let badge = make(evidence(.running, owner: "undecidable"), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .symbol("exclamationmark.triangle.fill"), tone: .warning,
                               label: "Running · not verified", clock: .none, suffix: nil))
    }

    @Test(arguments: ["unknown", "uncertain", "alive", "", "novel"])
    func givenRunningWithAnotherOwnerState_whenMatchingEvidenceExists_thenItIsPlainRunning(owner: String) {
        // given / when
        let badge = make(evidence(.running, owner: owner), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .spinner, tone: .running, label: "Running", clock: .live(Self.started), suffix: nil))
    }

    @Test(arguments: ["dead", "undecidable"])
    func givenAnOwnerWarningState_whenThereIsNoMatchingSnapshot_thenItIsPlainRunning(owner: String) {
        // given the owner state was carried without a matching snapshot behind it
        let evidence = TaskSnapshotEvidence(status: .running, takenOver: false, snapshotStatus: .completed, exitCode: nil,
                                            logState: nil, ownerState: owner, settledDuration: nil)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge.label == "Running")
        #expect(badge.clock == .live(Self.started))
    }

    @Test(arguments: terminal)
    func givenASettledStatus_whenTheOwnerIsDead_thenNoOwnerWarningShows(status: TaskStatus) {
        // given / when
        let badge = make(evidence(status, exit: 0, owner: "dead", duration: 5))

        // then
        #expect(badge.label == status.label)
        #expect(badge.tone != .warning)
    }

    // MARK: - Exit qualifiers

    @Test func givenDoneWithoutAnObservedExit_whenMatchingEvidenceExists_thenTheExitIsNotObserved() {
        // given / when
        let badge = make(evidence(.completed, exit: nil, duration: 90))

        // then a duration is never drawn beside an unobserved exit
        #expect(badge == Model(icon: .symbol("checkmark"), tone: .done, label: "Done · exit not observed", clock: .none, suffix: nil))
    }

    @Test(arguments: [EventLogState?.none, .open, .settling, .final, .incomplete, .unknown, .unavailable])
    func givenDoneWithoutAnExit_whenTheLogIsInAnyState_thenTheExitIsNotObserved(logState: EventLogState?) {
        // given / when
        let badge = make(evidence(.completed, logState: logState))

        // then
        #expect(badge.label == "Done · exit not observed")
    }

    @Test func givenFailedWithoutAnExit_whenTheLogIsIncomplete_thenTheExitIsNotObserved() {
        // given / when
        let badge = make(evidence(.failed, logState: .incomplete))

        // then
        #expect(badge == Model(icon: .symbol("xmark"), tone: .failed, label: "Failed · exit not observed", clock: .none, suffix: nil))
    }

    @Test(arguments: [EventLogState?.none, .open, .settling, .final, .unknown, .unavailable])
    func givenFailedWithoutAnExit_whenTheLogIsNotIncomplete_thenItIsPlainFailed(logState: EventLogState?) {
        // given / when
        let badge = make(evidence(.failed, logState: logState))

        // then
        #expect(badge.label == "Failed")
        #expect(badge.clock == .none)
    }

    @Test(arguments: [TaskStatus.failed, .completed])
    func givenAnExitQualifierStatus_whenThereIsNoMatchingSnapshot_thenItIsPlain(status: TaskStatus) {
        // given
        let evidence = evidence(status, matching: false, logState: .incomplete)

        // when
        let badge = make(evidence)

        // then
        #expect(badge.label == status.label)
    }

    @Test(arguments: [TaskStatus.timedOut, .cancelled])
    func givenTimedOutOrCancelledWithoutAnExit_whenMatchingEvidenceExists_thenThereIsNoQualifierAndNoClock(status: TaskStatus) {
        // given / when
        let badge = make(evidence(status, exit: nil, logState: .incomplete))

        // then
        #expect(badge.label == status.label)
        #expect(badge.clock == .none)
        #expect(badge.suffix == nil)
    }

    @Test func givenCancelledWithAnObservedExitAndDuration_whenMade_thenTheDurationShows() {
        // given / when
        let badge = make(evidence(.cancelled, exit: 130, duration: 271))

        // then
        #expect(badge.clock == .fixed(271))
    }

    // MARK: - Taken over

    @Test(arguments: everyKnownStatus)
    func givenATakenOverTask_whenMade_thenItKeepsTheReportedLabelAndAppendsTheSuffixWithNeutralStopIcon(status: TaskStatus) {
        // given
        let evidence = evidence(status, takenOver: true, exit: 0, duration: 271)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge.label == status.label)
        #expect(badge.suffix == "· taken over")
        #expect(badge.tone == .neutral)
        #expect(badge.icon == .symbol("stop.fill"))
        #expect(badge.accessibilityText(clock: nil).hasSuffix("· taken over"))
    }

    @Test func givenATakenOverCancelledTask_whenMade_thenTheLabelThenDurationThenSuffixAreOrdered() {
        // given
        let evidence = evidence(.cancelled, takenOver: true, exit: 130, duration: 271)

        // when
        let badge = make(evidence)

        // then the design's "Cancelled 04:31 · taken over"
        #expect(badge == Model(icon: .symbol("stop.fill"), tone: .neutral, label: "Cancelled", clock: .fixed(271), suffix: "· taken over"))
        #expect(badge.accessibilityText(clock: "04:31") == "Cancelled, 04:31, · taken over")
    }

    @Test func givenATakenOverRunningTask_whenTheOwnerIsDead_thenTakenOverWinsOverTheOwnerWarning() {
        // given
        let evidence = evidence(.running, takenOver: true, owner: "dead")

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge.label == "Running")
        #expect(badge.suffix == "· taken over")
        #expect(badge.tone == .neutral)
        #expect(badge.clock == .live(Self.started))
    }

    @Test(arguments: [TaskStatus.completed, .failed])
    func givenATakenOverTask_whenItsExitWasNotObserved_thenTakenOverWinsOverTheExitQualifier(status: TaskStatus) {
        // given
        let evidence = evidence(status, takenOver: true, exit: nil, logState: .incomplete)

        // when
        let badge = make(evidence)

        // then
        #expect(badge.label == status.label)
        #expect(badge.suffix == "· taken over")
    }

    @Test func givenATakenOverTask_whenThereIsNoMatchingSnapshot_thenItStillShowsTakenOver() {
        // given
        let evidence = evidence(.completed, matching: false, takenOver: true)

        // when
        let badge = make(evidence)

        // then
        #expect(badge.label == "Done")
        #expect(badge.suffix == "· taken over")
        #expect(badge.clock == .none)
    }

    // MARK: - Other statuses

    @Test func givenSettling_whenMade_thenItKeepsItsSpinnerAndRunningTintWithoutAClock() {
        // given / when
        let badge = make(evidence(.other("settling")), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .spinner, tone: .running, label: "Settling", clock: .none, suffix: nil))
    }

    @Test(arguments: ["needs input", "needs attention", "needs_attention"])
    func givenNeedsAttention_whenMade_thenItUsesTheAttentionToneAndIcon(raw: String) {
        // given / when
        let badge = make(evidence(.other(raw)), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .symbol("exclamationmark.triangle.fill"), tone: .attention,
                               label: "Needs attention", clock: .none, suffix: nil))
    }

    @Test(arguments: ["pending", "queued"])
    func givenPending_whenMade_thenItIsNeutralWithoutAClock(raw: String) {
        // given / when
        let badge = make(evidence(.other(raw)), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .symbol("circle"), tone: .neutral, label: "Pending", clock: .none, suffix: nil))
    }

    @Test func givenAnUnknownRawStatus_whenMade_thenItKeepsTheRawLabelOnThePlainTone() {
        // given / when
        let badge = make(evidence(.other("novel_state")), startedAt: Self.started)

        // then
        #expect(badge == Model(icon: .symbol("circle.dashed"), tone: .plain, label: "novel_state", clock: .none, suffix: nil))
    }

    @Test(arguments: otherStatuses)
    func givenAnOtherStatus_whenOwnerAndExitEvidenceExist_thenNoQualifierOrWarningApplies(status: TaskStatus) {
        // given
        let evidence = evidence(status, exit: nil, logState: .incomplete, owner: "dead", duration: 9)

        // when
        let badge = make(evidence, startedAt: Self.started)

        // then
        #expect(badge.clock == .none)
        #expect(badge.suffix == nil)
        #expect(badge.tone != .warning)
        #expect(!badge.label.contains("exit not observed"))
    }

    @Test func givenATakenOverOtherStatus_whenMade_thenTheSuffixStillApplies() {
        // given / when
        let badge = make(evidence(.other("settling"), takenOver: true))

        // then
        #expect(badge.label == "settling")
        #expect(badge.suffix == "· taken over")
        #expect(badge.tone == .neutral)
    }

    // MARK: - Every status, with and without evidence

    @Test(arguments: everyKnownStatus + otherStatuses, [true, false])
    func givenEveryStatus_whenMadeWithOrWithoutAMatchingSnapshot_thenALabelAlwaysExists(status: TaskStatus, matching: Bool) {
        // given / when
        let badge = make(evidence(status, matching: matching), startedAt: Self.started)

        // then
        #expect(!badge.label.isEmpty)
        #expect(badge.accessibilityText(clock: nil).hasPrefix(badge.label))
    }

    // MARK: - isPending

    @Test(arguments: ["pending", "queued", "PENDING", "Queued"])
    func givenAPendingRawStatus_whenAsked_thenItIsPending(raw: String) {
        // given / when / then
        #expect(Model.isPending(.other(raw)))
    }

    @Test(arguments: [TaskStatus.running, .completed, .failed, .timedOut, .cancelled, .other("settling"), .other("")])
    func givenAnyOtherStatus_whenAsked_thenItIsNotPending(status: TaskStatus) {
        // given / when / then
        #expect(!Model.isPending(status))
    }

    // MARK: - Accessibility text

    @Test func givenABadgeWithAClockAndSuffix_whenSpoken_thenPartsJoinInOrder() {
        // given
        let badge = Model(icon: .spinner, tone: .running, label: "Running", clock: .none, suffix: "· taken over")

        // when / then
        #expect(badge.accessibilityText(clock: "01:05") == "Running, 01:05, · taken over")
        #expect(badge.accessibilityText(clock: nil) == "Running, · taken over")
    }
}
