import MonitorCore
import PbUI
import SwiftUI

#if DEBUG
/// Overflowing dummy rows prove the feed's thin chrome and content fit together — no invented
/// production values, only `PreviewFixtures`' own fixture items.
@MainActor
private func activityFeedPreview() -> some View {
    let rows = ActivityRowsBuilder.build(from: PreviewFixtures.sampleRows(taskID: "feed-preview", running: false))
    let liveStep = LiveStep(rows: [], isRunning: true)
    return ActivityFeedView(rows: rows, start: .now.addingTimeInterval(-600), history: EventHistoryState(),
                            isLoading: false, tailValue: ActivityFeedTail(liveStep: liveStep), emptyText: nil,
                            state: ParallelColumnUIState(), onLoadMore: nil,
                            tailPresentation: .standard(.init(liveStep: .init(text: "Running the login tests…", indicator: .threeDots))))
    .frame(width: PbRadius.Metrics.timelinePanePreviewWidth, height: PbRadius.Metrics.taskDetailPreviewHeight)
    .background(Color.windowBG)
}

#Preview("ActivityFeed - light") { activityFeedPreview().preferredColorScheme(.light) }
#Preview("ActivityFeed - dark") { activityFeedPreview().preferredColorScheme(.dark) }
#endif
