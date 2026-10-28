import HfUI
@testable import MainWindowFeature
import MonitorCore
import Testing

struct ActivityFeedSnapshotTests {
    @Test func givenPreparedHistory_whenOnlyLastRowChanges_thenEarlierTokensAndIdleIdentityStayStable() {
        // given
        let rows = (0 ..< 3000).map { row($0, text: "Settled text \($0)") }
        let initial = ActivityFeedSnapshot.preparing(rows, previous: nil)
        // when
        let unchanged = ActivityFeedSnapshot.preparing(rows, previous: initial)
        var changed = rows
        changed[2999] = row(2999, text: "Streaming text appended")
        let streamed = ActivityFeedSnapshot.preparing(changed, previous: initial)
        // then
        #expect(unchanged === initial)
        #expect(streamed !== initial)
        for index in 0 ..< 2999 {
            #expect(streamed.tokens["snapshot-\(index)"] == initial.tokens["snapshot-\(index)"])
        }
        #expect(streamed.tokens["snapshot-2999"] != initial.tokens["snapshot-2999"])
    }

    private func row(_ index: Int, text: String) -> ActivityRow {
        .single(ConversationTimelineRow(id: "snapshot-\(index)", taskID: "snapshot-task", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(text, seq: index)), live: false))
    }
}
