import Foundation
@testable import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct PendingLaunchDetailPresentationTests {
    private let id = "20261110-093000-a17c92"
    private let settled = PendingLaunchDetailFlags(firstCheckSettled: true)
    private let utc = TimeZone(identifier: "UTC")!

    private func make(
        _ item: TaskPendingLaunchItem, flags: PendingLaunchDetailFlags? = nil, timeZone: TimeZone? = nil
    ) -> PendingLaunchDetailPresentation {
        .make(taskID: id, evidence: .value(PendingLaunchesFixture.lookup(item)), flags: flags ?? settled, timeZone: timeZone ?? utc)
    }

    private func make(plain disposition: String) -> PendingLaunchDetailPresentation {
        .make(taskID: id, evidence: .value(PendingLaunchesFixture.plainLookup(id: id, disposition: disposition)), flags: settled, timeZone: utc)
    }

    private func fact(_ label: String, in detail: PendingLaunchDetailPresentation) -> String? {
        detail.facts.first { $0.label == label }?.value
    }

    // MARK: - States

    @Test func givenEveryStoredState_whenMapped_thenExactTitleMessageAndAction() {
        // given
        let confirmation = "Harflow has not confirmed a running task yet."
        let cases: [(PendingLaunchDetailPresentation, PendingLaunchDetailPresentation.Kind, String, String, PendingLaunchDetailPresentation.Action)] = [
            (make(PendingLaunchesFixture.item(id: id, resources: ["Claude slots", "Shared checkout"])), .waiting, "Waiting for resources",
             "Waiting for Claude slots and Shared checkout. \(confirmation)", .checkAgain),
            (make(PendingLaunchesFixture.item(id: id, state: "reserved")), .preparing, "Preparing",
             "Harflow is preparing this launch. A running task has not been confirmed yet.", .checkAgain),
            (make(PendingLaunchesFixture.item(id: id, state: "claimed", cancelSupport: "unsupported")), .preparingHandshake,
             "Preparing · Stop unavailable",
             "This engine cannot stop this preparation yet. Stop becomes available after Harflow confirms the task has started.", .checkAgain),
            (make(PendingLaunchesFixture.item(id: id, state: "granted")), .granted, "Launch granted",
             "The engine granted this launch. \(confirmation)", .checkAgain),
            (make(PendingLaunchesFixture.item(id: id, state: "not_started", reason: "resource wait was cancelled")), .notStarted,
             "Did not start", "The engine recorded that this launch did not start. Reason: resource wait was cancelled.", .checkAgain),
            (make(plain: "not_found"), .missing, "Launch not found",
             "This ID was not found in the latest check. It may have started or changed elsewhere. Its outcome is unknown.", .checkAgain),
            (make(plain: "recorded"), .recorded, "Task record found", "Harflow found a task with this ID. Check its status to open it.",
             .checkTaskStatus)
        ]
        for (detail, kind, title, message, action) in cases {
            // then
            #expect(detail.kind == kind)
            #expect(detail.title == title)
            #expect(detail.message == message)
            #expect(detail.action == action)
            #expect(detail.isActionEnabled)
        }
        #expect(PendingLaunchDetailPresentation.note == "Harflow has not confirmed a running task yet. Messages and activity remain unavailable.")
    }

    @Test func givenNoEvidenceOrAFailure_whenMapped_thenPlaceholderUntilFirstCheckSettlesThenUnavailable() {
        // given / when
        let checking = PendingLaunchDetailPresentation.make(taskID: id, evidence: .none, flags: .init(), timeZone: utc)
        let refused = PendingLaunchDetailPresentation.make(taskID: id, evidence: .none, flags: settled, timeZone: utc)
        let failed = PendingLaunchDetailPresentation.make(taskID: id, evidence: .failed, flags: .init(), timeZone: utc)
        // then
        #expect(checking.kind == .checking)
        #expect(checking.title == "Checking launch status")
        #expect(checking.action == nil)
        #expect(checking.facts == [.init(label: "Selected ID", value: id, isCode: true)])
        for unavailable in [refused, failed] {
            #expect(unavailable.kind == .unavailable)
            #expect(unavailable.title == "Launch status unavailable")
            #expect(unavailable.message == "Harflow could not check this launch. Its outcome is unknown.")
            #expect(unavailable.action == .checkAgain)
            #expect(unavailable.facts == [.init(label: "Selected ID", value: id, isCode: true)])
        }
    }

    @Test func givenRefusedUnknownUnrecognizedOrUnrecognizedState_whenMapped_thenUnavailable() {
        // given / when / then
        for detail in [make(plain: "refused"), make(plain: "unknown"), make(plain: "future_disposition"),
                       make(PendingLaunchesFixture.item(id: id, state: "future_state"))] {
            #expect(detail.kind == .unavailable)
        }
    }

    @Test func givenUnrecognizedCancelSupport_whenMapped_thenPreparingWithoutUpgrade() throws {
        // given
        var raw = PendingLaunchesFixture.item(id: id, state: "claimed").raw
        raw["cancel_support"] = .string("future_mechanism")
        let item = try #require(TaskPendingLaunchItem(raw: raw))
        // when
        let detail = make(item)
        // then
        #expect(detail.kind == .preparing)
        #expect(detail.title == "Preparing")
    }

    // MARK: - Exact selection and handoff

    @Test func givenLookupForPreviousSelectionOnSameLease_whenMapped_thenItIsIgnored() throws {
        // given
        let lease = PendingLaunchReadLease()
        let previous = PendingLaunchSelection(taskID: id, lease: lease)
        let current = PendingLaunchSelection(taskID: id, lease: lease)
        let stored = PendingLaunchLookup(selection: previous, value: PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: id)), failure: nil)
        // when
        let first = PendingLaunchDetailPresentation.make(lookup: stored, input: .init(selection: current), timeZone: utc)
        let settledResult = PendingLaunchDetailPresentation.make(lookup: stored, input: .init(selection: current, flags: settled), timeZone: utc)
        let matching = PendingLaunchDetailPresentation.make(lookup: stored, input: .init(selection: previous), timeZone: utc)
        // then
        #expect(first.kind == .checking)
        #expect(settledResult.kind == .unavailable)
        #expect(matching.kind == .waiting)
    }

    @Test func givenStoredFailure_whenMapped_thenUnavailableEvenWithHandoffFailure() {
        // given
        let selection = PendingLaunchSelection(taskID: id, lease: PendingLaunchReadLease())
        let stored = PendingLaunchLookup(selection: selection, value: nil, failure: .unavailable)
        // when
        let detail = PendingLaunchDetailPresentation.make(
            lookup: stored, input: .init(selection: selection, flags: .init(firstCheckSettled: true, handoffFailed: true)), timeZone: utc
        )
        // then
        #expect(detail.kind == .unavailable)
    }

    @Test func givenHandoffFailure_whenStoredLookupIsRecorded_thenHandoffFailedWithCheckAgain() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, handoffFailed: true)
        let recorded = PendingLaunchesFixture.plainLookup(id: id, disposition: "recorded")
        let pending = PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: id))
        // when
        let failed = PendingLaunchDetailPresentation.make(taskID: id, evidence: .value(recorded), flags: flags, timeZone: utc)
        let notRecorded = PendingLaunchDetailPresentation.make(taskID: id, evidence: .value(pending), flags: flags, timeZone: utc)
        // then
        #expect(failed.kind == .handoffFailed)
        #expect(failed.title == "Task status unavailable")
        #expect(failed.message == "Harflow found a task, but could not check its status. Task controls remain unavailable.")
        #expect(failed.action == .checkAgain)
        #expect(notRecorded.kind == .waiting)
    }

    @Test func givenInFlightAction_whenMapped_thenActionIsDisabledNotHidden() {
        // given
        let flags = PendingLaunchDetailFlags(firstCheckSettled: true, isBusy: true)
        // when
        let detail = make(PendingLaunchesFixture.item(id: id), flags: flags)
        // then
        #expect(detail.action == .checkAgain)
        #expect(!detail.isActionEnabled)
    }

    // MARK: - Facts

    @Test func givenQualifiedLaunch_whenMapped_thenFactsAreInOrderWithFullValues() {
        // given / when
        let detail = make(PendingLaunchesFixture.item(id: id, resources: ["Claude slots", "Shared checkout"]))
        // then
        #expect(detail.facts.map(\.label) == ["Launch ID", "Harness", "Repository", "Created", "Resources"])
        #expect(detail.facts.map(\.value) == [id, "Claude", "/projects/Harflow", "10 Nov 2026, 09:30", "Claude slots · Shared checkout"])
        #expect(detail.facts.map(\.isCode) == [true, false, false, false, false])
    }

    @Test func givenMissingOrBlankSources_whenMapped_thenThoseFactsAreOmittedAndEmptyResourcesSaySo() {
        // given / when
        let detail = make(PendingLaunchesFixture.item(id: id, backend: nil, repoPath: "  ", createdAt: "not a date"))
        let noDate = make(PendingLaunchesFixture.item(id: id, createdAt: nil))
        // then
        #expect(detail.facts.map(\.label) == ["Launch ID", "Resources"])
        #expect(fact("Resources", in: detail) == "None requested")
        #expect(fact("Created", in: noDate) == nil)
    }

    @Test func givenCreatedTimestamps_whenFormatted_thenFixedShapeInTheGivenZone() {
        // given
        let jakarta = TimeZone(identifier: "Asia/Jakarta")!
        // when
        let plain = make(PendingLaunchesFixture.item(id: id, createdAt: "2026-11-10T09:30:00Z"))
        let fractional = make(PendingLaunchesFixture.item(id: id, createdAt: "2026-11-10T09:30:45.123456+00:00"))
        let shifted = make(PendingLaunchesFixture.item(id: id, createdAt: "2026-11-10T09:30:00Z"), timeZone: jakarta)
        let single = make(PendingLaunchesFixture.item(id: id, createdAt: "2026-03-05T04:07:00Z"))
        // then
        #expect(fact("Created", in: plain) == "10 Nov 2026, 09:30")
        #expect(fact("Created", in: fractional) == "10 Nov 2026, 09:30")
        #expect(fact("Created", in: shifted) == "10 Nov 2026, 16:30")
        #expect(fact("Created", in: single) == "5 Mar 2026, 04:07")
    }

    // MARK: - Variable copy

    @Test func givenResourceNames_whenJoined_thenEnglishListWithoutLocalizedAnd() {
        // given / when / then
        #expect(PendingLaunchDetailPresentation.joinedResources([]) == nil)
        #expect(PendingLaunchDetailPresentation.joinedResources(["A"]) == "A")
        #expect(PendingLaunchDetailPresentation.joinedResources(["A", "B"]) == "A and B")
        #expect(PendingLaunchDetailPresentation.joinedResources(["A", "B", "C"]) == "A, B and C")
    }

    @Test func givenWaitingWithoutResources_whenMapped_thenMessageIsOnlyTheConfirmationSentence() {
        // given / when
        let detail = make(PendingLaunchesFixture.item(id: id))
        // then
        #expect(detail.message == "Harflow has not confirmed a running task yet.")
    }

    @Test func givenNotStartedReason_whenMapped_thenTrimmedWithoutDoubledPeriodOrDroppedWhenBlank() {
        // given / when
        let plain = make(PendingLaunchesFixture.item(id: id, state: "not_started", reason: "  resource wait was cancelled  "))
        let dotted = make(PendingLaunchesFixture.item(id: id, state: "not_started", reason: "resource wait was cancelled."))
        let blank = make(PendingLaunchesFixture.item(id: id, state: "not_started", reason: "   "))
        let absent = make(PendingLaunchesFixture.item(id: id, state: "not_started", reason: nil))
        // then
        #expect(plain.message == "The engine recorded that this launch did not start. Reason: resource wait was cancelled.")
        #expect(dotted.message == plain.message)
        #expect(blank.message == "The engine recorded that this launch did not start.")
        #expect(absent.message == blank.message)
    }
}
