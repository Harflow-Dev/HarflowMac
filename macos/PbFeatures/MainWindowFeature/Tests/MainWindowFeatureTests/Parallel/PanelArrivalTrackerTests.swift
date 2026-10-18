import Foundation
@testable import MainWindowFeature
import Testing

@Suite struct PanelArrivalTrackerTests {
    @Test func givenUnreadyCatalog_whenHistoryResolves_thenEstablishesBaselineWithoutAnimation() {
        // given
        var tracker = PanelArrivalTracker()
        let now = Date(timeIntervalSince1970: 100)
        // when
        #expect(tracker.update([], authoritative: false, now: now).isEmpty)
        let initial = tracker.update([(id: "old", startedAt: now)], authoritative: true, now: now)
        // then
        #expect(initial.isEmpty)
        #expect(tracker.update([(id: "old", startedAt: now)], authoritative: true, now: now).isEmpty)
    }

    @Test func givenLoadedBaseline_whenBatchArrives_thenOnlyNewConversationsAnimate() {
        // given
        var tracker = PanelArrivalTracker()
        let now = Date(timeIntervalSince1970: 100)
        _ = tracker.update([(id: "first", startedAt: now)], authoritative: true, now: now)
        // when
        let result = tracker.update([(id: "first", startedAt: now), (id: "new1", startedAt: now),
                                     (id: "new2", startedAt: now), (id: "paged", startedAt: now.addingTimeInterval(-10))], authoritative: true)
        // then
        #expect(result == ["new1", "new2"])
    }

    @Test func givenConversationIdentity_whenResumeUpdates_thenNoNewEntrance() {
        // given
        var tracker = PanelArrivalTracker()
        let now = Date()
        _ = tracker.update([(id: "conversation", startedAt: now)], authoritative: true, now: now)
        // when
        let result = tracker.update([(id: "conversation", startedAt: now)], authoritative: true)
        // then
        #expect(result.isEmpty)
    }

    @Test func givenNewPanelAlreadyPresented_whenRemovedAndReinserted_thenDoesNotAnimateAgain() {
        // given
        var tracker = PanelArrivalTracker()
        let now = Date()
        _ = tracker.update([], authoritative: true, now: now)
        #expect(tracker.update([(id: "new", startedAt: now)], authoritative: true) == ["new"])
        tracker.didPresent("new")
        // when
        _ = tracker.update([], authoritative: true)
        let reinserted = tracker.update([(id: "new", startedAt: now)], authoritative: true)
        // then
        #expect(reinserted.isEmpty)
    }
}
