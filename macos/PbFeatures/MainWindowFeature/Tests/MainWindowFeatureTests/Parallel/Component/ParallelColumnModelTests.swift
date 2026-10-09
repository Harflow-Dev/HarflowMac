import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

@Suite struct ParallelColumnModelTests {

    private func rows(_ count: Int) -> [ConversationTimelineRow] {
        (0 ..< count).map { index in
            ConversationTimelineRow(
                id: "t1#\(index)", taskID: "t1", timestamp: nil,
                kind: .item(PreviewFixtures.textItem("step \(index)", seq: index)), live: false
            )
        }
    }

    private func activity(_ count: Int) -> [ActivityRow] {
        ActivityRowsBuilder.build(from: rows(count))
    }

    @Test func givenLoadedActivity_whenRevealingOlderRows_thenEachBatchIsBoundedAndTheBoundaryPersists() {
        // given
        let ids = activity(250).map(\.id)
        // when / then
        #expect(ActivityFeedWindow.firstIndex(ids: ids, retainedID: nil) == 150)
        let older = ActivityFeedWindow.olderBoundary(ids: ids, retainedID: nil)
        #expect(older == ids[50])
        #expect(ActivityFeedWindow.olderBoundary(ids: ids, retainedID: older) == ids[0])
        #expect(ActivityFeedWindow.olderBoundary(ids: ids, retainedID: ids[0]) == nil)
        #expect(ActivityFeedWindow.firstIndex(ids: ids + ["new"], retainedID: ids[50]) == 50)
    }

    @Test func givenNearTopViewport_whenLoadingEligibilityChanges_thenMountRestorationNeighborsErrorsAndBusyAreExcluded() {
        // given / when / then
        func eligible(_ positioned: Bool = true, _ restoring: Bool = false, _ visible: Bool = true,
                      _ loading: Bool = false, _ error: String? = nil, _ offset: CGFloat = 199) -> Bool {
            ActivityFeedWindow.shouldLoad(offset: offset, viewport: 400,
                eligibility: ActivityFeedEligibility(positioned: positioned, restoring: restoring, visible: visible, loading: loading, error: error))
        }
        #expect(eligible())
        #expect(!eligible(false))
        #expect(!eligible(true, true))
        #expect(!eligible(true, false, false))
        #expect(!eligible(true, false, true, true))
        #expect(!eligible(true, false, true, false, "retry"))
        #expect(!eligible(true, false, true, false, nil, 201))
    }

    @Test func givenASeparator_whenCountingSteps_thenItDoesNotCountAsActivity() {
        // given
        let values = rows(5) + [ConversationTimelineRow(id: "sep:t2", taskID: "t2", timestamp: nil,
            kind: .separator(text: "continue"), live: false)]
        // when / then
        #expect(ParallelColumnModel.itemCount(values) == 5)
    }

    // MARK: - Subtitle

    @Test func givenASingleTurnConversation_whenBuildingTheSubtitle_thenItIsRepoAndBackendOnly() {
        // given / when
        let subtitle = ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge/", backend: "claude", turns: 1)

        // then
        #expect(subtitle == "polybridge · Claude")
    }

    @Test func givenAMultiTurnConversation_whenBuildingTheSubtitle_thenTheTurnCountIsAppended() {
        // given / when
        let subtitle = ParallelColumnModel.subtitle(repoPath: "/Users/me/Code/polybridge", backend: "codex", turns: 3)

        // then
        #expect(subtitle == "polybridge · Codex · 3 turns")
    }
}
