import Foundation
@testable import HfRepository
import HfTestUtilities
import Testing

// MARK: - NeedsYouCadenceTests

@Suite struct NeedsYouCadenceTests {
    @Test func givenVisibleWindow_whenLoopStarts_thenNextPassIsScheduledAtThreeSeconds() async {
        // given
        let scheduler = CapturingScheduler()
        let sut = makeSUT(FakeNeedsYouEngine(), scheduler: scheduler, visibility: FakeMonitorVisibility(mainWindowVisible: true))
        // when
        sut.start()
        // then
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        #expect(scheduler.oneShotCount(interval: 3) == 1)
    }

    @Test func givenHiddenWindow_whenLoopStarts_thenNextPassIsScheduledAtFifteenSeconds() async {
        // given
        let scheduler = CapturingScheduler()
        let sut = makeSUT(FakeNeedsYouEngine(), scheduler: scheduler, visibility: FakeMonitorVisibility(mainWindowVisible: false))
        // when
        sut.start()
        // then
        await waitUntil { scheduler.oneShotCount(interval: 15) == 1 }
        #expect(scheduler.oneShotCount(interval: 15) == 1)
    }

    @Test func givenHiddenWindow_whenItBecomesVisible_thenAPassRunsImmediately() async {
        // given
        let scheduler = CapturingScheduler()
        let visibility = FakeMonitorVisibility(mainWindowVisible: false)
        let fake = FakeNeedsYouEngine()
        let sut = makeSUT(fake, scheduler: scheduler, visibility: visibility)
        sut.start()
        await waitUntil { scheduler.oneShotCount(interval: 15) == 1 }
        #expect(scheduler.oneShotCount(interval: 15) == 1)
        let before = fake.calls.count
        // when
        visibility.setMainWindowVisible(true)
        // then
        await waitUntil { fake.calls.count > before }
        #expect(fake.calls.count > before)
        await waitUntil { scheduler.oneShotCount(interval: 3) >= 1 }
        #expect(scheduler.oneShotCount(interval: 3) >= 1)
    }

    @Test func givenStartedTwice_whenScheduling_thenOnlyOneLoopRuns() async {
        // given
        let scheduler = CapturingScheduler()
        let sut = makeSUT(FakeNeedsYouEngine(), scheduler: scheduler)
        // when
        sut.start()
        sut.start()
        // then
        await waitUntil { scheduler.oneShotCount(interval: 3) == 1 }
        #expect(scheduler.oneShotCount(interval: 3) == 1)
        #expect(scheduler.oneShotCount(interval: 3) == 1)
    }
}
