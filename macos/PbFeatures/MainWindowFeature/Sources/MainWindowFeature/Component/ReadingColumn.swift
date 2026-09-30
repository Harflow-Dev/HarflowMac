//
//  ReadingColumn.swift
//  MainWindowFeature
//
//  Settled plan D13: task content reads in a centred column at most 720 pt wide that shrinks with
//  the window. Applied INSIDE each scroll view rather than around it, so the scroll view itself
//  spans the pane and its scrollbar sits at the window's right edge, not the column's.
//

import SwiftUI

// MARK: - ReadingColumn

extension View {
    /// Centres this content in a column at most `ReadingColumn.maxWidth` wide.
    func readingColumn() -> some View {
        frame(maxWidth: ReadingColumn.maxWidth, alignment: .leading).frame(maxWidth: .infinity)
    }
}

enum ReadingColumn {
    static let maxWidth: CGFloat = 720
}
