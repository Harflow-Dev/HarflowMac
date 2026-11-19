import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - WorkflowSelectedPaneApprovalSizingTests

/// The pending-approval rule of the selected-node pane, as pure sizing: the card takes its natural height first, the feed
/// yields to nothing, then the goal region yields, then an oversized card scrolls. With nothing awaiting a decision the
/// allocations are today's.
@Suite struct WorkflowSelectedPaneApprovalSizingTests {

    // MARK: Top region

    @Test func givenNoDemand_whenSizingTopRegion_thenAllocationIsUnchanged() {
        // given: a 500 pt pane with 240 pt of chrome
        // when
        let plain = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: 500, reserved: 240)
        let zero = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: 500, reserved: 240, approvalDemand: 0)
        // then
        #expect(plain == 180)
        #expect(zero == plain)
    }

    @Test func givenSmallCard_whenSizingTopRegion_thenRegionKeepsTodaysHeightAndFeedYieldsFirst() {
        // given: pane 500, chrome 240; today's region is 180 and leaves the feed its 80 pt floor
        let pane: CGFloat = 500
        let reserved: CGFloat = 240
        // when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: reserved, approvalDemand: 60)
        // then: the card's 60 pt comes out of the feed (80 -> 20), the region is not cut
        #expect(top == 180)
        #expect(pane - reserved - top - 60 == 20)
    }

    @Test func givenCardLargerThanTheFeed_whenSizingTopRegion_thenRegionYieldsAfterTheFeedReachesZero() {
        // given
        let pane: CGFloat = 500
        let reserved: CGFloat = 240
        // when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: reserved, approvalDemand: 250)
        // then: 500 - 240 - 250 = 10 left for the region; the feed is exactly 0
        #expect(top == 10)
        #expect(pane - reserved - top - 250 == 0)
    }

    @Test func givenCardNeverFitsAlongsideChrome_whenSizingTopRegion_thenRegionIsZeroAndNeverNegative() {
        // given / when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: 500, reserved: 240, approvalDemand: 400)
        let tiny = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: 100, reserved: 240, approvalDemand: 400)
        // then
        #expect(top == 0)
        #expect(tiny == 0)
    }

    @Test func givenSmallNaturalRegion_whenCardAwaits_thenRegionKeepsItsNaturalHeight() {
        // given / when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 40, paneHeight: 800, reserved: 240, approvalDemand: 250)
        // then
        #expect(top == 40)
    }

    @Test func givenDemandOnAPaneWithLessRoomThanToday_whenSizingTopRegion_thenItNeverExceedsTodaysAllocation() {
        // given: pane - reserved = 200 and a region taller than that; today's limit is 120 (200 - 80 floor)
        let pane: CGFloat = 400
        let reserved: CGFloat = 200
        // when
        let today = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: reserved)
        let pending = WorkflowSelectedPaneSizing.topRegionHeight(natural: 900, paneHeight: pane, reserved: reserved, approvalDemand: 40)
        // then: the region stays at 120 and the feed keeps the 40 pt left, not the region growing to 160
        #expect(today == 120)
        #expect(pending == 120)
        #expect(pane - reserved - pending - 40 == 40)
    }

    // MARK: Approval region

    @Test func givenNoRequestAwaiting_whenSizingApproval_thenTodaysTableHolds() {
        // given / when / then
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 60, columnHeight: 500) == 60)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 500) == 225)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 120) == 40)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 400, columnHeight: 500, chrome: 100, pending: false) == 225)
    }

    @Test func givenRequestAwaitingAndCardFits_whenSizingApproval_thenItTakesNaturalHeight() {
        // given: a 500 pt column with 100 pt of chrome leaves 400 pt for the card and the feed
        // when
        let height = WorkflowSelectedPaneSizing.approvalHeight(natural: 250, columnHeight: 500, chrome: 100, pending: true)
        // then
        #expect(height == 250)
    }

    @Test func givenCardTallerThanFortyFivePercentButFitting_whenAwaiting_thenTheShareCapIsLifted() {
        // given: natural 300 is above 45% of 500 (225) yet fits under column - chrome = 400
        // when
        let pending = WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 500, chrome: 100, pending: true)
        let idle = WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 500, chrome: 100, pending: false)
        // then
        #expect(pending == 300)
        #expect(idle == 225)
    }

    @Test func givenCardLargerThanTheColumn_whenAwaiting_thenRegionIsColumnMinusChrome() {
        // given / when
        let height = WorkflowSelectedPaneSizing.approvalHeight(natural: 900, columnHeight: 500, chrome: 100, pending: true)
        // then: the feed is 0 and the card scrolls inside the region
        #expect(height == 400)
    }

    @Test func givenCardBeyondTheFloor_whenAwaiting_thenTheFeedMayDropBelowItsFloor() {
        // given: the idle rule would leave the feed 80 pt; the pending rule leaves it nothing
        let column: CGFloat = 400
        let chrome: CGFloat = 100
        // when
        let pending = WorkflowSelectedPaneSizing.approvalHeight(natural: 250, columnHeight: column, chrome: chrome, pending: true)
        // then
        #expect(column - chrome - pending == 50)
        #expect(column - chrome - pending < WorkflowSelectedPaneSizing.transcriptFloor)
    }

    @Test func givenChromeLeavingLessRoomThanTheBar_whenAwaiting_thenRegionNeverExceedsTheColumn() {
        // given: chrome leaves 30 pt, less than a 60 pt bar
        // when
        let height = WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 130, chrome: 100, pending: true)
        // then
        #expect(height == 30)
    }

    @Test func givenDegenerateInputs_whenAwaiting_thenHeightIsNeverNegative() {
        // given / when / then
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 50, chrome: 100, pending: true) == 0)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 0, columnHeight: 500, chrome: 100, pending: true) == 0)
        #expect(WorkflowSelectedPaneSizing.approvalHeight(natural: 300, columnHeight: 0, pending: true) == 0)
    }

    @Test func givenAnyPane_whenAwaiting_thenCardRegionAndFeedFillTheColumnWithoutOverflow() {
        // given: pane 480 (1000x620 window), head 60, column chrome 150, a 260 pt card and a 600 pt goal
        let pane: CGFloat = 480
        let head: CGFloat = 60
        let chrome: CGFloat = 150
        let demand: CGFloat = 260
        // when
        let top = WorkflowSelectedPaneSizing.topRegionHeight(natural: 600, paneHeight: pane, reserved: head + chrome + 1, approvalDemand: demand)
        let column = pane - head - top - 1
        let region = WorkflowSelectedPaneSizing.approvalHeight(natural: demand, columnHeight: column, chrome: chrome, pending: true)
        let feed = column - chrome - region
        // then: the card is whole, the feed is what is left, and the goal region gave up the difference
        #expect(region == demand)
        #expect(feed >= 0)
        #expect(top == 9)
        #expect(feed == 0)
    }
}
