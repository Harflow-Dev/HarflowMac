import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

// MARK: - EventStreamRepositoryImplTests

@Suite struct EventStreamRepositoryImplTests {
    @Test func givenDuplicateAndRegressingPublicSequences_whenLoaded_thenEveryOccurrenceSurvivesWithoutAssignmentFallback() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        // when
        let records = [ObservationFixtures.record(7), ObservationFixtures.record(7), ObservationFixtures.record(6)]
        harness.reader.finish(0, .success(ObservationFixtures.page(records)))
        await waitUntil { sut.observation(for: "task").records.count == 3 }
        // then
        let frame = sut.observation(for: "task")
        #expect(frame.records.map(\.record.seq) == [7, 7, 6])
        #expect(Set(frame.records.map(\.id)).count == 3)
        #expect(frame.events.map(\.seq) == [7, 7, 6])
        #expect(frame.summary.counts == nil)
        #expect(sut.requestState(for: "task") == .notRequested)
        #expect(sut.prompt(for: "task") == nil)
    }

    @Test func givenTwoActivityLeases_whenOneReleasesTwice_thenExactOtherRoleSurvivesAndSnapshotRefreshedOnce() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let first = sut.acquire("task")
        let second = sut.acquire("task")
        await waitUntil { harness.reader.requests.count == 1 }
        await verify(harness.snapshots).refresh(.value("task")).calledEventually(1, before: .seconds(3))
        // when
        first.release()
        first.release()
        // then
        #expect(sut.leasedTaskIDs == ["task"])
        #expect(harness.reader.requests[0].isCurrent())
        verify(harness.snapshots).refresh(.value("task")).called(1)
        second.release()
        #expect(sut.leasedTaskIDs.isEmpty)
        #expect(!harness.reader.requests[0].isCurrent())
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        #expect(sut.observation(for: "task").records.isEmpty)
    }

    @Test func givenSummaryOnlyRole_whenQualified_thenNoActivityMaterializesAndNoSnapshotRefreshOccurs() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquireSummary("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        // when
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "file")])))
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page()))
        await waitUntil { sut.observation(for: "task").summary.state == .observed }
        // then
        #expect(sut.observation(for: "task").summary.counts?.edits == 1)
        #expect(sut.observation(for: "task").records.isEmpty)
        #expect(sut.items(for: "task").isEmpty)
        #expect(sut.leasedTaskIDs.isEmpty)
        verify(harness.snapshots).refresh(.any).called(0)
    }

    @Test func givenSummarySurvivesActivityRelease_whenActivityReacquires_thenBoundedWindowAnchorsAndSummaryRemainWhileReadsResumeAtRetainedCursor() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let summary = sut.acquireSummary("task")
        let activity = sut.acquire("task")
        defer { summary.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "file")], newer: "activity-cursor")))
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page(newer: "summary-cursor")))
        await waitUntil { sut.observation(for: "task").summary.state == .observed }
        let original = sut.observation(for: "task")
        // when
        activity.release()
        #expect(sut.leasedTaskIDs.isEmpty)
        harness.tick()
        await waitUntil { harness.reader.requests.count == 3 }
        #expect(harness.reader.requests[2].position == .cursor("summary-cursor"))
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "summary-next")))
        let replacement = sut.acquire("task")
        defer { replacement.release() }
        await waitUntil { harness.reader.requests.count == 4 }
        #expect(harness.reader.requests[3].position == .cursor("activity-cursor"))
        #expect(sut.observation(for: "task").records == original.records)
        harness.reader.finish(3, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "activity-next")))
        await waitUntil { sut.observation(for: "task").records.count == 2 }
        // then
        let current = sut.observation(for: "task")
        #expect(current.scope == original.scope)
        #expect(current.records.first?.id == original.records.first?.id)
        #expect(current.summary == original.summary)
        #expect(current.summary.counts?.edits == 1)
        await verify(harness.snapshots).refresh(.value("task")).calledEventually(2, before: .seconds(3))
        #expect(harness.reader.requests.count == 4)
    }

    @Test func givenOldLifetimeReleased_whenNewLeaseExists_thenOldReleaseAndLateResultCannotEraseNewRows() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let old = sut.acquire("task")
        await waitUntil { harness.reader.requests.count == 1 }
        old.release()
        let current = sut.acquire("task")
        defer { current.release() }
        await waitUntil { harness.reader.requests.count == 2 }
        // when
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.record(2)], capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        old.release()
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        // then
        #expect(!harness.reader.requests[0].isCurrent())
        #expect(harness.reader.requests[1].isCurrent())
        #expect(sut.events(for: "task").map(\.seq) == [2])
        #expect(sut.leasedTaskIDs == ["task"])
    }

    @Test func givenRuntimeSelectionABA_whenActiveRolesReconnect_thenOldReadsAreFencedAndExactRoleReleasesRemainValid() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let selection = CurrentValueSubject<String, Never>("A")
        sut.bindRuntimeChanges(selection)
        let activity = sut.acquire("task")
        let summary = sut.acquireSummary("task")
        defer { summary.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        // when
        selection.send("B")
        await waitUntil { harness.reader.requests.count == 2 }
        selection.send("A")
        // Cancelled reads retain global admission until their callbacks return.
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        await waitUntil { harness.reader.requests.count == 3 }
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(3)], capture: "future_capture")))
        await waitUntil { sut.events(for: "task").map(\.seq) == [3] }
        harness.reader.finish(1, .failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "old runtime")))
        // then
        #expect(!harness.reader.requests[0].isCurrent())
        #expect(!harness.reader.requests[1].isCurrent())
        #expect(sut.leasedTaskIDs == ["task"])
        #expect(sut.events(for: "task").map(\.seq) == [3])
        activity.release()
        #expect(sut.events(for: "task").map(\.seq) == [3])
        #expect(sut.leasedTaskIDs.isEmpty)
        #expect(harness.reader.requests[2].isCurrent())
    }

    @Test func givenSummaryOnlyRoleWithOlderHistory_whenActionRequested_thenNoActivityDemandIsGranted() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquireSummary("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(older: "earlier", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").history.hasOlder }
        let scope = sut.observation(for: "task").scope
        // when
        let accepted = sut.requestObservation(action: .loadEarlier, for: "task", scope: scope)
        // then
        #expect(!accepted)
        #expect(harness.reader.requests.count == 1)
        #expect(sut.observation(for: "task").records.isEmpty)
    }

    @Test func givenPublicSummaryWithManyFiles_whenLegacyExpansionRequested_thenPublishedFilesStayBoundedAndTotalRemainsQualified() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquireSummary("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        let records = (1 ... 200).map { ObservationFixtures.call($0, id: "call-\($0)", path: "file-\($0)") }
        harness.reader.finish(0, .success(ObservationFixtures.page(records)))
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page()))
        await waitUntil { sut.observation(for: "task").summary.state == .observed }
        // when
        sut.loadMoreSummaryFiles("task")
        // then
        let summary = sut.observation(for: "task").summary
        #expect(summary.counts?.edits == 200)
        #expect(summary.totalFiles == 200)
        #expect(summary.files.count == 100)
        #expect(sut.events(for: "task").isEmpty)
        #expect(harness.reader.requests.count == 2)
    }

    @Test func givenRuntimeReplacement_whenOldScopeRequestsAnAction_thenCurrentSessionIsNotAffected() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(older: "old-earlier", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").history.hasOlder }
        let oldScope = sut.observation(for: "task").scope
        // when
        sut.invalidateRuntime()
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .success(ObservationFixtures.page(older: "new-earlier", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").history.hasOlder }
        // then
        #expect(sut.observation(for: "task").scope != oldScope)
        #expect(!sut.requestObservation(action: .loadEarlier, for: "task", scope: oldScope))
        #expect(harness.reader.requests.count == 2)
    }

    @Test func givenOneSourceAdoptionAlreadySpent_whenSourceRefusesAgain_thenNoInertAdoptionActionIsOfferedOrAccepted() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)], newer: "first", capture: "future_capture")))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        harness.tick()
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .failure(.refused(code: "cursor_invalid", message: "first source changed")))
        await waitUntil { sut.observation(for: "task").history.availableActions.contains(.adoptCurrentSource) }
        let oldScope = sut.observation(for: "task").scope
        #expect(sut.requestObservation(action: .adoptCurrentSource, for: "task", scope: oldScope))
        await waitUntil { harness.reader.requests.count == 3 }
        harness.reader.finish(2, .success(ObservationFixtures.page([ObservationFixtures.record(2)], newer: "second")))
        await waitUntil { sut.events(for: "task").map(\.seq) == [2] }
        let retained = sut.observation(for: "task")
        // when
        harness.tick()
        await waitUntil { harness.reader.requests.count == 4 }
        harness.reader.finish(3, .failure(.refused(code: "cursor_expired", message: "second source changed")))
        await waitUntil { sut.observation(for: "task").history.currentness == .sourceChangePending }
        // then
        let current = sut.observation(for: "task")
        #expect(current.records == retained.records)
        #expect(current.scope == retained.scope)
        #expect(current.history.reasons.contains(.resetExhausted))
        #expect(!current.history.availableActions.contains(.adoptCurrentSource))
        #expect(!sut.requestObservation(action: .adoptCurrentSource, for: "task", scope: current.scope))
        #expect(harness.reader.requests.count == 4)
        #expect(current.summary.counts == nil)
    }

    @Test func givenPublicUnsupportedRecord_whenLoaded_thenRawEvidenceRemainsAndSemanticRowsDoNotInventPayload() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        // when
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1, "future_kind")])))
        await waitUntil { sut.observation(for: "task").records.count == 1 }
        // then
        #expect(sut.events(for: "task").isEmpty)
        #expect(sut.items(for: "task").isEmpty)
        #expect(sut.observation(for: "task").history.reasons.contains(.unknownKind))
        #expect(sut.observation(for: "task").summary.counts == nil)
    }
}
