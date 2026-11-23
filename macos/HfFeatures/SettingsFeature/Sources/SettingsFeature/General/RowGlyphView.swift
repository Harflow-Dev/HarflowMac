import HfUI
import SwiftUI

// MARK: - RowGlyphView

/// The glyph at the start of a Settings status row: the shared spinner, check and cross, or an alert circle in
/// the warning colour for attention (not the Needs-you hand).
struct RowGlyphView: View {
    let glyph: RowGlyph

    var body: some View {
        if let status = glyph.status {
            StatusIcon(status: status)
                .accessibilityLabel(glyph.accessibilityLabel)
        } else if let symbol = glyph.attentionSymbol {
            Image(systemName: symbol)
                .font(.hf(.body))
                .foregroundStyle(Color.warningFG)
                .frame(width: HfRadius.Metrics.statusIconSize, height: HfRadius.Metrics.statusIconSize)
                .accessibilityLabel(glyph.accessibilityLabel)
        }
    }
}
