@testable import MainWindowFeature
import Testing

struct FollowLiveScrollTests {
    @Test func givenInitialFeed_whenPositionStartsAboveBottom_thenInitialFollowingRemainsEnabled() {
        // given
        var state = FollowLiveScrollState()
        // when
        state.observe(offset: 0, contentHeight: 1000, viewportHeight: 300)
        // then
        #expect(state.isFollowing)
    }

    @Test func givenFollowingAtBottom_whenContentGrows_thenFollowingRemainsEnabled() {
        // given
        var state = FollowLiveScrollState()
        state.observe(offset: 700, contentHeight: 1000, viewportHeight: 300)
        // when
        state.observe(offset: 700, contentHeight: 1400, viewportHeight: 300)
        // then
        #expect(state.isFollowing)
    }

    @Test func givenFollowingAtBottom_whenUserScrollsUp_thenFollowingStops() {
        // given
        var state = FollowLiveScrollState()
        state.observe(offset: 700, contentHeight: 1000, viewportHeight: 300)
        // when
        state.observe(offset: 500, contentHeight: 1000, viewportHeight: 300)
        // then
        #expect(!state.isFollowing)
    }

    @Test func givenReadingOlderActivity_whenNewContentArrives_thenFollowingStaysStopped() {
        // given
        var state = FollowLiveScrollState()
        state.observe(offset: 700, contentHeight: 1000, viewportHeight: 300)
        state.observe(offset: 500, contentHeight: 1000, viewportHeight: 300)
        // when
        state.observe(offset: 500, contentHeight: 1400, viewportHeight: 300)
        // then
        #expect(!state.isFollowing)
    }

    @Test func givenReadingOlderActivity_whenUserReturnsToBottom_thenFollowingResumes() {
        // given
        var state = FollowLiveScrollState()
        state.observe(offset: 700, contentHeight: 1000, viewportHeight: 300)
        state.observe(offset: 400, contentHeight: 1000, viewportHeight: 300)
        // when
        state.observe(offset: 600, contentHeight: 1000, viewportHeight: 300)
        #expect(!state.isFollowing)
        state.observe(offset: 690, contentHeight: 1000, viewportHeight: 300)
        // then
        #expect(state.isFollowing)
    }

    @Test func givenHistoryRequested_whenContentChangesWithoutScrolling_thenSuspensionRemains() {
        // given
        var state = FollowLiveScrollState()
        state.observe(offset: 700, contentHeight: 1000, viewportHeight: 300)
        state.suspend()
        // when
        state.observe(offset: 700, contentHeight: 1600, viewportHeight: 300)
        // then
        #expect(!state.isFollowing)
    }

    @Test func givenShortFeed_whenContentFitsViewport_thenFollowingRemainsEnabled() {
        // given
        var state = FollowLiveScrollState()
        state.suspend()
        // when
        state.observe(offset: 0, contentHeight: 200, viewportHeight: 300)
        // then
        #expect(state.isFollowing)
    }
}
