//
//  ReadingColumn.swift
//  MainWindowFeature
//
//  Settled plan D13 / redesign §6.2: task content reads in a centred column at most 760 pt wide
// that shrinks with the window. The 760 includes the 24 pt inner padding on each side of the
// content (712 pt usable), so the reading measure and the insets stay one token. Applied INSIDE
// each scroll view rather than around it, so the scroll view itself spans the pane and its
// scrollbar sits at the window's right edge, not the column's.
//

import PbUI
import SwiftUI

// MARK: - ReadingColumn

extension View {
    /// Centres this content in a column at most `ReadingColumn.maxWidth` wide.
    func readingColumn() -> some View {
        frame(maxWidth: ReadingColumn.maxWidth, alignment: .leading).frame(maxWidth: .infinity)
    }
}

enum ReadingColumn {
    static var maxWidth: CGFloat { PbRadius.Metrics.taskColumnMaxWidth }
}
