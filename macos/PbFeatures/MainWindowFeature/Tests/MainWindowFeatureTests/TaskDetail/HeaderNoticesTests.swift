@testable import MainWindowFeature
import Testing

// MARK: - HeaderNoticesTests

@Suite struct HeaderNoticesTests {

    @Test func givenFewerNoticesThanTheCap_whenBuilt_thenAllShowWithNoMoreLine() {
        // given
        let notices = ["one", "two"]

        // when
        let sut = HeaderNotices(notices)

        // then
        #expect(sut.shown == ["one", "two"])
        #expect(sut.hiddenCount == 0)
        #expect(sut.moreText == nil)
    }

    @Test func givenMoreNoticesThanTheCap_whenBuilt_thenOnlyTheFirstShowAndTheRestAreCounted() {
        // given
        let notices = ["a", "b", "c", "d", "e"]

        // when
        let sut = HeaderNotices(notices)

        // then
        #expect(sut.shown == ["a", "b", "c"])
        #expect(sut.hiddenCount == 2)
        #expect(sut.moreText == "+2 more notices in the inspector")
    }

    @Test func givenOneNoticeOverTheCap_whenBuilt_thenTheMoreLineIsSingular() {
        // given
        let notices = ["a", "b", "c", "d"]

        // when
        let sut = HeaderNotices(notices)

        // then
        #expect(sut.moreText == "+1 more notice in the inspector")
    }
}
