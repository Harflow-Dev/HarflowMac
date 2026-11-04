import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

@Suite struct TaskListInvalidationSourceTests {
    @Test func givenHiddenIdle_whenElapsedTimeReachesThirtySeconds_thenOneInvalidationArrivesWithoutThirtyTicks() {
        // given
        let scheduler = CapturingScheduler()
        let start = scheduler.now()
        let calls = LockedBox(0)
        let token = PollingTaskListInvalidationSource(scheduler: scheduler).observe(isUrgent: { false }) {
            calls.mutate { $0 += 1 }
        }
        #expect(scheduler.repeatIntervals == [1])
        // when / then — tick count alone does not advance time.
        scheduler.fireFirstRepeat(times: 100)
        #expect(calls.value == 0)
        scheduler.advance(to: start.addingTimeInterval(29))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 0)
        scheduler.advance(to: start.addingTimeInterval(30))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 1)
        scheduler.fireFirstRepeat(times: 100)
        #expect(calls.value == 1)
        withExtendedLifetime(token) {}
    }

    @Test func givenUrgencyChanges_whenNextTickArrives_thenFastPolicyStartsAndHiddenIntervalRestarts() {
        // given
        let scheduler = CapturingScheduler()
        let start = scheduler.now()
        let urgent = LockedBox(false)
        let calls = LockedBox(0)
        let token = PollingTaskListInvalidationSource(scheduler: scheduler).observe(isUrgent: { urgent.value }) {
            calls.mutate { $0 += 1 }
        }
        // when / then
        scheduler.advance(to: start.addingTimeInterval(1))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 0)
        urgent.mutate { $0 = true }
        scheduler.fireFirstRepeat()
        scheduler.advance(to: start.addingTimeInterval(2))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 2)
        urgent.mutate { $0 = false }
        scheduler.advance(to: start.addingTimeInterval(31))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 2)
        scheduler.advance(to: start.addingTimeInterval(32))
        scheduler.fireFirstRepeat()
        #expect(calls.value == 3)
        withExtendedLifetime(token) {}
    }

    @Test func givenCancelledSubscription_whenRetainedSchedulerCallbackFires_thenItCannotInvalidate() {
        // given
        let scheduler = CapturingScheduler()
        let calls = LockedBox(0)
        let token = PollingTaskListInvalidationSource(scheduler: scheduler).observe(isUrgent: { true }) {
            calls.mutate { $0 += 1 }
        }
        // when
        token.cancel()
        scheduler.fireFirstRepeat(times: 100)
        // then
        #expect(calls.value == 0)
    }

    @Test func givenClockMovesBackwards_whenTickArrives_thenItRefreshesConservatively() {
        // given
        let scheduler = CapturingScheduler()
        let calls = LockedBox(0)
        let token = PollingTaskListInvalidationSource(scheduler: scheduler).observe(isUrgent: { false }) {
            calls.mutate { $0 += 1 }
        }
        // when
        scheduler.advance(to: scheduler.now().addingTimeInterval(-1))
        scheduler.fireFirstRepeat()
        // then
        #expect(calls.value == 1)
        withExtendedLifetime(token) {}
    }
}

@Suite struct TaskHistoryRefreshCoordinatorPollTests {
    @Test func givenPollPassInFlight_whenManyTicksArrive_thenNoFollowupIsArmed() async {
        // given
        let sut = TaskHistoryRefreshCoordinator()
        #expect(await sut.tryBeginPollIfIdle())
        let owed = await sut.beginPass()
        // when
        for _ in 0 ..< 100 { #expect(!(await sut.tryBeginPollIfIdle())) }
        // then
        #expect(!(await sut.endPass(owed: owed, result: .success(()))))
        #expect(await sut.tryBeginPollIfIdle())
        let next = await sut.beginPass()
        #expect(!(await sut.endPass(owed: next, result: .success(()))))
    }

    @Test func givenPollPassInFlight_whenActionRegisters_thenItsLaterPassStillCompletes() async {
        // given
        let sut = TaskHistoryRefreshCoordinator()
        #expect(await sut.tryBeginPollIfIdle())
        let first = await sut.beginPass()
        let registered = LockedBox(false)
        let completed = LockedBox(false)
        let action = Task {
            let result: Result<Void, ToolError> = await withCheckedContinuation { continuation in
                Task {
                    let starts = await sut.registerWaiter(continuation)
                    #expect(!starts)
                    registered.mutate { $0 = true }
                }
            }
            completed.mutate { $0 = true }
            return result
        }
        await waitUntil { registered.value }
        // when
        for _ in 0 ..< 100 { #expect(!(await sut.tryBeginPollIfIdle())) }
        #expect(await sut.endPass(owed: first, result: .success(())))
        #expect(!completed.value)
        let second = await sut.beginPass()
        #expect(second.count == 1)
        #expect(!(await sut.endPass(owed: second, result: .success(()))))
        // then
        guard case .success = await action.value else {
            Issue.record("action waiter did not receive its later successful pass")
            return
        }
        #expect(completed.value)
    }
}
