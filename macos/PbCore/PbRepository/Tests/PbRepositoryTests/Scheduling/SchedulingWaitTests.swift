import Combine
import Foundation
@testable import PbRepository
import Testing

// MARK: - SchedulingWaitTests

/// `Scheduling.wait(for:)` — the awaited counterpart of `schedule(after:)`, driven through a
/// capturing scheduler: the captured closure is fired by the test, never a real timer and never
/// `NullScheduling` (whose one-shot never fires, which would make a "did not proceed" assertion
/// vacuous).
@Suite struct SchedulingWaitTests {

    private func capturingScheduler() -> (scheduler: CapturingScheduler, fired: LockedBox<Int>) {
        let scheduler = CapturingScheduler()
        let fired = LockedBox(0)
        return (scheduler, fired)
    }

    @Test func givenAWait_whenTheScheduledClosureFires_thenTheWaitEnds() async throws {
        // given
        let (scheduler, fired) = capturingScheduler()

        // when
        let waiter = Task {
            try await scheduler.wait(for: 2)
            fired.mutate { $0 += 1 }
        }
        while scheduler.oneShots.isEmpty { await Task.yield() }
        scheduler.fireFirstOneShot()
        try await waiter.value

        // then
        #expect(fired.value == 1)
        #expect(scheduler.oneShots.isEmpty)
    }

    @Test func givenAWait_whenTheWaitingTaskIsCancelled_thenItThrowsAndFiresNothing() async throws {
        // given
        let (scheduler, fired) = capturingScheduler()
        let cancelled: LockedBox<Bool> = LockedBox(false)

        // when
        let waiter = Task {
            do {
                try await scheduler.wait(for: 5)
                fired.mutate { $0 += 1 }
            } catch {
                cancelled.mutate { $0 = true }
            }
        }
        while scheduler.oneShots.isEmpty { await Task.yield() }
        waiter.cancel()
        await waiter.value

        // then — the wait ended through the cancellation path, and the never-fired closure did
        // not count as a tick.
        #expect(cancelled.value)
        #expect(fired.value == 0)
    }

    @Test func givenAWait_whenCancellationBeatsTheFiringRace_thenExactlyOneResumeWins() async {
        // given
        let (scheduler, _) = capturingScheduler()
        let outcomes = LockedBox(0)

        // when — cancel immediately after the wait starts; the once-resume gate must keep the
        // later fire() a no-op (a double resume would trap).
        let waiter = Task {
            do { try await scheduler.wait(for: 1) } catch { outcomes.mutate { $0 += 1 } }
        }
        while scheduler.oneShots.isEmpty { await Task.yield() }
        waiter.cancel()
        scheduler.fireFirstOneShot()
        await waiter.value

        // then
        #expect(outcomes.value == 1)
    }
}

// MARK: - MonitorVisibilityTests

@Suite struct MonitorVisibilityTests {

    @Test func givenRepeatedEqualWrites_whenObserved_thenThePublisherEmitsOnChangeOnly() {
        // given
        let visibility = SystemMonitorVisibility(mainWindowVisible: true)
        var received: [Bool] = []
        let token = visibility.mainWindowVisiblePublisher()
            .sink { received.append($0) }

        // when
        visibility.setMainWindowVisible(true)
        visibility.setMainWindowVisible(false)
        visibility.setMainWindowVisible(false)
        visibility.setMainWindowVisible(true)
        token.cancel()

        // then — the initial value plus one emission per change, nothing for the repeats.
        #expect(received == [true, false, true])
    }

    @Test func givenAHiddenWindow_whenWaitingForVisibility_thenTheNextShowReturns() async {
        // given
        let visibility = SystemMonitorVisibility(mainWindowVisible: false)
        visibility.setMainWindowVisible(false)

        // when
        let waiter = Task { await visibility.waitForMainWindowVisible() }
        // The publisher's first emission is the current `false`; park until the flip below.
        await Task.yield()
        await Task.yield()
        visibility.setMainWindowVisible(true)
        await waiter.value

        // then
        #expect(visibility.mainWindowVisible)
    }

    @Test func givenAVisibleWindow_whenWaitingForVisibility_thenItReturnsImmediately() async {
        // given
        let visibility = SystemMonitorVisibility(mainWindowVisible: true)
        // when / then
        await visibility.waitForMainWindowVisible()
        #expect(visibility.mainWindowVisible)
    }

    @Test func givenPopoverWrites_whenObserved_thenTheyDedupeOnTheirOwnChannel() {
        // given
        let visibility = SystemMonitorVisibility()
        var received: [Bool] = []
        let token = visibility.menuBarPopoverOpenPublisher().sink { received.append($0) }

        // when
        visibility.setMenuBarPopoverOpen(false)
        visibility.setMenuBarPopoverOpen(true)
        visibility.setMenuBarPopoverOpen(true)
        token.cancel()

        // then
        #expect(received == [false, true])
        #expect(visibility.mainWindowVisible)
    }

    @Test func givenTheNullDefault_whenRead_thenItFailsSafeVisibleAndNeverBlocks() async {
        // given
        let visibility = NullMonitorVisibility()
        // when / then
        #expect(visibility.mainWindowVisible)
        #expect(!visibility.menuBarPopoverOpen)
        await visibility.waitForMainWindowVisible()
        visibility.setMainWindowVisible(false)
        #expect(visibility.mainWindowVisible)
    }
}
