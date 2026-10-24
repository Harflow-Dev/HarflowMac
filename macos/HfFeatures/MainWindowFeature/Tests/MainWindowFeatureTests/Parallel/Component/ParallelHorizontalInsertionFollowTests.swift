import AppKit
@testable import MainWindowFeature
import Testing

@MainActor @Suite struct ParallelHorizontalInsertionFollowTests {
    @Test func givenStableHorizontalContext_whenWorkingColumnsArriveInOnePublication_thenFirstInsertionIsTargeted() {
        // given
        let follow = ParallelHorizontalInsertionFollow()
        let configuration = ParallelHorizontalConfiguration(workingColumnIDs: ["work-a", "work-b"], contextID: "group")
        _ = follow.configure(.init(previousIDs: ["a", "b"], ids: ["a", "b"],
                                   configuration: configuration, offset: 0, isUserScrolling: false))

        // when
        _ = follow.configure(.init(previousIDs: ["a", "b"], ids: ["a", "work-a", "work-b", "b"],
                                   configuration: configuration, offset: 0, isUserScrolling: false))

        // then
        #expect(follow.targetID == "work-a")
    }

    @Test(arguments: [true, false])
    func givenHorizontalInsertion_whenContextOrUserIntentChanges_thenPendingFollowIsCancelled(
        userIsScrolling: Bool
    ) {
        // given
        let follow = ParallelHorizontalInsertionFollow()
        let configuration = ParallelHorizontalConfiguration(workingColumnIDs: ["work"], contextID: "group")
        _ = follow.configure(.init(previousIDs: ["a"], ids: ["a"], configuration: configuration,
                                   offset: 0, isUserScrolling: false))

        // when
        if userIsScrolling {
            _ = follow.configure(.init(previousIDs: ["a"], ids: ["work", "a"],
                                       configuration: configuration, offset: 200, isUserScrolling: true))
        } else {
            _ = follow.configure(.init(previousIDs: ["a"], ids: ["work", "a"], configuration: configuration,
                                       offset: 0, isUserScrolling: false))
            #expect(follow.targetID == "work")
            _ = follow.configure(.init(previousIDs: ["work", "a"], ids: ["work", "a"],
                                       configuration: ParallelHorizontalConfiguration(
                                           workingColumnIDs: ["work"], contextID: "other"),
                                       offset: 0, isUserScrolling: false))
        }

        // then
        #expect(follow.targetID == nil)
    }

    @Test func givenPendingHorizontalLayoutOffset_whenLayoutCompletes_thenTheRememberedOffsetIsConsumedOnce() {
        // given
        let follow = ParallelHorizontalInsertionFollow()
        follow.rememberOffset(421, layoutReady: false)

        // when / then
        #expect(follow.consumeOffset(fallback: 0) == 421)
        #expect(follow.consumeOffset(fallback: 0) == 0)
    }

    @Test func givenRapidHorizontalLayoutUpdates_whenLayoutIsNotReady_thenTheFirstOffsetIsRetained() {
        // given
        let follow = ParallelHorizontalInsertionFollow()

        // when
        follow.rememberOffset(421, layoutReady: false)
        follow.rememberOffset(842, layoutReady: false)

        // then — one native correction is coalesced until the document is measurable.
        #expect(follow.consumeOffset(fallback: 0) == 421)
    }
}
