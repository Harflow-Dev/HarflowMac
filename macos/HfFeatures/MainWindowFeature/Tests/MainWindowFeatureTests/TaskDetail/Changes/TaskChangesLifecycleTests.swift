import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - TaskChangesLifecycleTests

/// The read bookkeeping values: the fence, the lifecycle defaults and the cadence constants.
struct TaskChangesLifecycleTests {

    @Test func givenTheCadenceConstants_whenRead_thenTheyAreFiveFifteenAndThreeHundredSeconds() {
        // given / when / then
        #expect(TaskChangesLifecycle.firstSettlingDelay == 5)
        #expect(TaskChangesLifecycle.settlingDelay == 15)
        #expect(TaskChangesLifecycle.settlingCap == 300)
    }

    @Test func givenAFreshFence_whenAGenerationAdvances_thenOnlyTheLatestIsCurrent() {
        // given
        let fence = TaskChangesFence()

        // when
        fence.advance(to: 3)

        // then
        #expect(fence.isCurrent(3))
        #expect(!fence.isCurrent(2))
        #expect(!fence.isCurrent(4))

        // when
        fence.advance(to: 4)

        // then
        #expect(fence.isCurrent(4) && !fence.isCurrent(3))
    }

    @Test func givenManyThreadsReadingWhileTheFenceAdvances_whenFinished_thenTheFinalGenerationIsCurrent() async {
        // given
        let fence = TaskChangesFence()

        // when
        await withTaskGroup(of: Void.self) { group in
            for generation in 1 ... 50 as ClosedRange<UInt64> {
                group.addTask { fence.advance(to: generation); _ = fence.isCurrent(generation) }
            }
        }
        fence.advance(to: 99)

        // then
        #expect(fence.isCurrent(99))
    }

    @Test func givenAFreshLifecycle_whenRead_thenAReadIsOwedAndNothingIsSettlingOrCapped() {
        // given / when
        let lifecycle = TaskChangesLifecycle()

        // then
        #expect(lifecycle.paneOpen == nil)
        #expect(lifecycle.needsRead)
        #expect(!lifecycle.appliedSettling && !lifecycle.capped)
        #expect(lifecycle.generation == 0 && lifecycle.settlingResults == 0 && lifecycle.supersededRetries == 0)
        #expect(lifecycle.memberIDs.isEmpty && lifecycle.memberID == nil && lifecycle.shownStatus == nil && lifecycle.settlingSince == nil)
    }
}
