@testable import MainWindowFeature
import Testing

@Suite struct WorkflowActivityReadingStateTests {
    @Test func givenUnattributedLayoutChanges_whenContentAndViewportChange_thenFollowDecisionDoesNotChange() {
        var state = WorkflowActivityReadingState()
        state.positioned(at: 400)
        state.beginInput(upward: true)
        state.userPosition(400, upward: true)

        state.settle(contentHeight: 1_200, viewportHeight: 300)
        state.settle(contentHeight: 1_200, viewportHeight: 450)

        #expect(!state.following)
        #expect(state.offset == 400)
        #expect(!state.interacting)
        #expect(!state.pendingInput)
    }

    @Test func givenOwnedInputMakesNoMovementAtBottom_whenDispatchEnds_thenPendingAttributionClears() {
        var state = WorkflowActivityReadingState()
        state.positioned(at: 700)
        state.beginInput(upward: true)

        #expect(!state.following && state.pendingInput && state.interacting)
        state.endInput(contentHeight: 1_000, viewportHeight: 300)

        #expect(!state.following && state.upwardIntent)
        #expect(state.offset == 700)
        #expect(!state.pendingInput && !state.interacting)

        // Neither a near-bottom observation nor later content growth erases upward intent.
        state.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(!state.following && state.upwardIntent)
        state.settle(contentHeight: 1_300, viewportHeight: 300)
        #expect(!state.following && state.upwardIntent && !state.pendingInput && !state.interacting)
    }

    @Test func givenLegacyWheelWithoutLiveScrollPair_whenAttributedPositionArrives_thenReadingPositionPausesFollow() {
        var state = WorkflowActivityReadingState()
        state.beginInput(upward: true)
        state.userPosition(420, upward: true)
        state.endInput(contentHeight: 1_000, viewportHeight: 300)

        #expect(!state.following)
        #expect(state.offset == 420)
        #expect(!state.pendingInput && !state.interacting)
    }

    @Test func givenNearBottomDuringMomentum_whenUserReturnsToBottom_thenResumeWaitsUntilIdle() {
        var state = WorkflowActivityReadingState()
        state.positioned(at: 400)
        state.setLiveScrolling(true)
        state.beginInput(upward: true)
        state.userPosition(390, upward: true)
        state.setMomentum(true)
        state.setLiveScrolling(false)
        state.userPosition(690, upward: false)

        state.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(!state.following && state.interacting)
        #expect(state.offset == 690)

        state.setMomentum(false)
        state.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(state.following && !state.interacting)
    }

    @Test func givenScrollerTrackingNearBottom_whenTrackingEnds_thenFollowResumes() {
        var state = WorkflowActivityReadingState()
        state.positioned(at: 500)
        state.setScrollerTracking(true)
        state.beginInput(upward: true)
        state.userPosition(690, upward: false)
        state.settle(contentHeight: 1_000, viewportHeight: 300)

        #expect(!state.following && state.interacting)
        state.setScrollerTracking(false)
        state.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(state.following && !state.interacting)
    }

    @Test func givenUpwardIntentAtNearBottomBoundary_whenIdleSettles_thenTwentyFourAndTwentyFivePointsStayPaused() {
        var atBoundary = WorkflowActivityReadingState()
        atBoundary.positioned(at: 676)
        atBoundary.beginInput(upward: true)
        atBoundary.userPosition(676, upward: true)
        atBoundary.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(!atBoundary.following && atBoundary.upwardIntent)
        atBoundary.beginInput(upward: false)
        atBoundary.endInput(contentHeight: 1_000, viewportHeight: 300)
        #expect(!atBoundary.following && atBoundary.upwardIntent,
                "A non-upward dispatch without movement must not re-arm follow")

        var outsideBoundary = WorkflowActivityReadingState()
        outsideBoundary.positioned(at: 675)
        outsideBoundary.beginInput(upward: true)
        outsideBoundary.userPosition(675, upward: true)
        outsideBoundary.settle(contentHeight: 1_000, viewportHeight: 300)
        #expect(!outsideBoundary.following && outsideBoundary.upwardIntent)
    }

    @Test func givenUpwardIntent_whenActualDownwardMovementReachesNearBottom_thenIdleSettleRearmsFollow() {
        var state = WorkflowActivityReadingState()
        state.positioned(at: 675)
        state.beginInput(upward: true)
        state.userPosition(675, upward: true)
        state.endInput(contentHeight: 1_000, viewportHeight: 300)
        #expect(!state.following && state.upwardIntent)

        state.beginInput(upward: false)
        state.userPosition(676, upward: false, downward: true)
        state.endInput(contentHeight: 1_000, viewportHeight: 300)

        #expect(state.following && !state.upwardIntent)
        #expect(!state.pendingInput && !state.interacting)
    }
}
