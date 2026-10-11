import AppKit
@testable import MainWindowFeature
import PbUI
import SwiftUI
import Testing

// MARK: - TaskDetailPresentationLayoutTests

@MainActor @Suite(.serialized) struct TaskDetailPresentationLayoutTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenFourReportedMetrics_whenHostedAtDefaultAndNarrowWidths_thenTheyFitInOneRowOrStack(scheme: ColorScheme) {
        // given
        _ = NSApplication.shared
        let tiles = [
            SummaryStatTile(title: "Duration", value: "21:00"), SummaryStatTile(title: "Agent turns", value: "12"),
            SummaryStatTile(title: "Tokens (in / out)", value: "48,210 / 3,150"), SummaryStatTile(title: "Cost", value: "$0.4213")
        ]
        let usableWidth = PbRadius.Metrics.taskColumnMaxWidth - 2 * PbRadius.Metrics.spacing24
        // when — measure the actual production view, including tile padding.
        let wide = size(SummaryStatTilesView(tiles: tiles), width: usableWidth, scheme: scheme)
        let narrow = size(SummaryStatTilesView(tiles: tiles), width: PbRadius.Metrics.activityPreviewWidth, scheme: scheme)
        let oneTile = size(SummaryStatTilesView(tiles: Array(tiles.prefix(1))), width: usableWidth, scheme: scheme)
        // then
        #expect(wide.width <= usableWidth)
        #expect(abs(wide.height - oneTile.height) < 1)
        #expect(narrow.width <= PbRadius.Metrics.activityPreviewWidth)
        #expect(narrow.height >= wide.height * 3)
    }

    private func size(_ view: some View, width: CGFloat, scheme: ColorScheme) -> CGSize {
        let host = NSHostingView(rootView: view.preferredColorScheme(scheme)
            .frame(width: width)
.fixedSize(horizontal: false, vertical: true))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }
}
