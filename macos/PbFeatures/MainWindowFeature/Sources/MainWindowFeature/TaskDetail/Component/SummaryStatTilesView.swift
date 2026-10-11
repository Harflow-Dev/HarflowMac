import PbUI
import SwiftUI

// MARK: - SummaryStatTilesView

/// Current agent run metrics: four bounded tiles fit the default reading measure and stack in narrow panes.
struct SummaryStatTilesView: View {
    let tiles: [SummaryStatTile]

    /// §6.2's responsive tile row: fixed-width, leading-aligned tiles that never stretch to the
    /// pane's full width, and — when the column is too narrow for the whole row — the tiles wrap
    /// into a vertical list instead of clipping. Values use `.headline` semibold with tabular
    /// digits.
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: PbRadius.Metrics.summaryTileSpacing) {
                ForEach(tiles) { tile in
                    statTile(tile)
                }
            }
            VStack(alignment: .leading, spacing: PbRadius.Metrics.summaryTileSpacing) {
                ForEach(tiles) { tile in
                    statTile(tile)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statTile(_ tile: SummaryStatTile) -> some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing4) {
            Text(tile.title).font(.pb(.caption)).foregroundStyle(Color.tertiaryText)
            Text(tile.value)
.font(.pb(.headline, weight: .semibold))
.monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(PbRadius.Metrics.spacing12)
        .frame(width: PbRadius.Metrics.summaryTileWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: PbRadius.card).fill(Color.cardFill))
        .overlay(RoundedRectangle(cornerRadius: PbRadius.card).stroke(Color.cardBorder, lineWidth: PbRadius.Metrics.hairlineStroke))
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
private let previewTiles = [
    SummaryStatTile(title: "Duration", value: "21:00"),
    SummaryStatTile(title: "Agent turns", value: "12"),
    SummaryStatTile(title: "Tokens (in / out)", value: "48,210 / 3,150"),
    SummaryStatTile(title: "Cost", value: "$0.4213")
]

#Preview("Stat row - light") {
    SummaryStatTilesView(tiles: previewTiles)
.frame(width: PbRadius.Metrics.taskColumnMaxWidth)
        .preferredColorScheme(.light)
}

#Preview("Stat row - dark") {
    SummaryStatTilesView(tiles: previewTiles)
.frame(width: PbRadius.Metrics.taskColumnMaxWidth)
        .preferredColorScheme(.dark)
}

#Preview("Narrow stat stack - light") {
    SummaryStatTilesView(tiles: previewTiles)
.frame(width: PbRadius.Metrics.activityPreviewWidth)
        .preferredColorScheme(.light)
}

#Preview("Narrow stat stack - dark") {
    SummaryStatTilesView(tiles: previewTiles)
.frame(width: PbRadius.Metrics.activityPreviewWidth)
        .preferredColorScheme(.dark)
}
#endif
