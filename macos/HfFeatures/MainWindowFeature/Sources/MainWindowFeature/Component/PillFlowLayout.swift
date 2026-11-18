//
//  PillFlowLayout.swift
//  MainWindowFeature
//

import HfUI
import SwiftUI

// MARK: - PillFlowLayout

/// Places subviews left to right and wraps to a new line when the next one does not fit.
struct PillFlowLayout: Layout {
    var spacing: CGFloat = HfRadius.Metrics.spacing6
    /// How items of different heights sit within their row. `.top` keeps the original placement.
    var rowAlignment: VerticalAlignment = .top

    /// Packs items, left to right, into rows of at most `maxWidth`; returns each row's item indices.
    /// An item wider than the line sits alone on its row, and an item that exactly fills the line fits.
    nonisolated static func rows(itemWidths: [CGFloat], maxWidth: CGFloat, spacing: CGFloat) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var x: CGFloat = 0
        for (index, width) in itemWidths.enumerated() {
            if !current.isEmpty, x + width > maxWidth {
                rows.append(current)
                current = []
                x = 0
            }
            current.append(index)
            x += width + spacing
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        return CGSize(width: proposal.width ?? result.usedWidth, height: result.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, frame) in result.frames.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (frames: [CGRect], usedWidth: CGFloat, height: CGFloat) {
        // Capped at the line width so a long file name truncates instead of overflowing the column.
        let sizes: [CGSize] = subviews.map { subview in
            let natural = subview.sizeThatFits(.unspecified)
            return natural.width > width ? subview.sizeThatFits(ProposedViewSize(width: width, height: nil)) : natural
        }
        let rows = Self.rows(itemWidths: sizes.map(\.width), maxWidth: width, spacing: spacing)
        var frames = [CGRect](repeating: .zero, count: sizes.count)
        var y: CGFloat = 0
        var usedWidth: CGFloat = 0
        for (rowIndex, row) in rows.enumerated() {
            let rowHeight = row.map { sizes[$0].height }.max() ?? 0
            var x: CGFloat = 0
            for index in row {
                let size = sizes[index]
                let offset = rowAlignment == .center ? (rowHeight - size.height) / 2 : 0
                frames[index] = CGRect(origin: CGPoint(x: x, y: y + offset), size: size)
                x += size.width + spacing
            }
            usedWidth = max(usedWidth, x - spacing)
            y += rowHeight + (rowIndex < rows.count - 1 ? spacing : 0)
        }
        return (frames, usedWidth, y)
    }
}
