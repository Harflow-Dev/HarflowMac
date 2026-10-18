import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeTailAnchorTests {
    @Test func givenViewportWhollyInsideTallLiveTail_whenTailAndStructureChange_thenActualTailLocationStaysPaused() async throws {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(state, revision: 0, preceding: 2))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) { state.viewportPositioned }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        let tailIndex = try #require(owner.entries.firstIndex { $0.id == "activity-feed-tail" })
        let tail = table.rect(ofRow: tailIndex)
        try #require(tail.height > scroll.contentView.bounds.height * 3)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: tail.minY + 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 3) { !state.followLive.isFollowing && activityNativeVisibleTail(host) != nil }
        let baseline = scroll.documentVisibleRect.minY - tail.minY
        try #require(scroll.documentVisibleRect.minY > tail.minY)
        try #require(scroll.documentVisibleRect.maxY < tail.maxY)
        for revision in 1 ... 2 {
            host.rootView = feed(state, revision: revision, preceding: revision == 1 ? 2 : 3)
            await waitUntil(timeout: 3) {
                activityNativeCommittedTailStrings(host).contains { $0.contains("revision \(revision)") }
                    && activityNativeVisibleTail(host) != nil
            }
            let index = try #require(owner.entries.firstIndex { $0.id == "activity-feed-tail" })
            let actual = table.rect(ofRow: index)
            #expect(abs(scroll.documentVisibleRect.minY - actual.minY - baseline) < 3)
            #expect(!state.followLive.isFollowing)
            #expect(scroll.documentVisibleRect.maxY < actual.maxY)
        }
        window.setContentSize(CGSize(width: 340, height: 450))
        await waitUntil(timeout: 3) { abs(scroll.contentView.bounds.width - 340) < 2 && activityNativeVisibleTail(host) != nil }
        let resizedIndex = try #require(owner.entries.firstIndex { $0.id == "activity-feed-tail" })
        #expect(abs(scroll.documentVisibleRect.minY - table.rect(ofRow: resizedIndex).minY - baseline) < 3)
        #expect(!state.followLive.isFollowing)
    }

    private func feed(_ state: ParallelColumnUIState, revision: Int, preceding: Int) -> some View {
        let rows = (0 ..< preceding).map { index in
            ActivityRow.single(ConversationTimelineRow(id: "tail-anchor-row-\(index)", taskID: "tail-anchor-task", timestamp: nil,
                kind: .item(PreviewFixtures.textItem("Preceding timeline row \(index)", seq: index)), live: false))
        }
        let pending = (0 ..< 45).map { index in
            PendingMessage(id: "tall-pending-\(index)", text: "Pending message \(index) remains in the live tail, revision \(revision)")
        }
        return ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
            tailValue: ActivityFeedTail(pendingMessages: pending), state: state, onLoadMore: nil,
            tailPresentation: .standard(.init(pendingMessages: pending,
                liveStep: .init(text: "Live tail revision \(revision)", indicator: .singleDot))))
            .environment(\.pbReduceMotionOverride, true)
    }
}
