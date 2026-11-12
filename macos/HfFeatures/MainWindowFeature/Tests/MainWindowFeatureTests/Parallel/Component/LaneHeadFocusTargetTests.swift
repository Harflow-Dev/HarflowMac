@testable import MainWindowFeature
import Testing

// MARK: - LaneHeadFocusTargetTests

/// The lane title is a keyboard target only while a requested focus move is in flight or holds.
@Suite struct LaneHeadFocusTargetTests {
    @Test func givenNoRequest_whenCreated_thenTheTitleIsNotATarget() {
        #expect(LaneHeadFocusTarget().isTarget == false)
    }

    @Test func givenARequest_whenTheDeferredFocusFails_thenTheTitleStopsBeingATarget() {
        // given
        var target = LaneHeadFocusTarget()
        target.request()
        #expect(target.isTarget)

        // when
        target.attemptFinished(focused: false)

        // then
        #expect(target.isTarget == false)
    }

    @Test func givenARequest_whenTheDeferredFocusSucceeds_thenTheTitleStaysATargetUntilFocusIsLost() {
        // given
        var target = LaneHeadFocusTarget()
        target.request()

        // when / then
        target.attemptFinished(focused: true)
        #expect(target.isTarget)
        target.focusLost()
        #expect(target.isTarget == false)
    }

    @Test func givenARequestInFlight_whenTheHeadDisappears_thenTheTitleStopsBeingATarget() {
        // given
        var target = LaneHeadFocusTarget()
        target.request()

        // when — the head's `onDisappear` reports focus lost
        target.focusLost()

        // then
        #expect(target.isTarget == false)
    }
}
