import Foundation
@testable import MainWindowFeature
import Testing

@Suite struct AdoptionFocusTrackerTests {
    @Test func givenARequest_whenTheNoticeClears_thenFocusMovesToTheHeadOnce() {
        var tracker = AdoptionFocusTracker()
        tracker.requestAdoption()
        #expect(tracker.noticeChanged(from: "Cached history is not current.", to: nil) == .loaded)
        #expect(tracker.noticeChanged(from: "Again", to: nil) == .none, "a later clear does not move focus again")
    }

    @Test func givenARequest_whenAdoptionFailsWithAnotherNotice_thenTheRequestEndsWithoutMovingFocus() {
        var tracker = AdoptionFocusTracker()
        tracker.requestAdoption()
        #expect(tracker.noticeChanged(from: "Cached history is not current.", to: "The reading window could not be replaced.") == .failed)
        #expect(!tracker.isAwaiting)
        let later = tracker.noticeChanged(from: "The reading window could not be replaced.", to: nil)
        #expect(later == .none, "a later, unrelated clear is not a completed adoption")
    }

    @Test func givenNoRequest_whenTheNoticeClears_thenNothingHappens() {
        var tracker = AdoptionFocusTracker()
        #expect(tracker.noticeChanged(from: "Cached history is not current.", to: nil) == .none)
    }

    @Test func givenARequestAndTheSameNotice_whenItRepeats_thenTheRequestStaysPending() {
        var tracker = AdoptionFocusTracker()
        tracker.requestAdoption()
        #expect(tracker.noticeChanged(from: "Same", to: "Same") == .none)
        #expect(tracker.isAwaiting)
        tracker.cancel()
        #expect(!tracker.isAwaiting)
    }
}
