import Foundation

// MARK: - MarkdownListNesting

/// List nesting carried line to line: the indentation columns of the open list items.
///
/// Both Markdown parsers use this helper so a block's list depth is identical whether the text is
/// parsed whole or incrementally.
struct MarkdownListNesting: Equatable, Sendable {
    /// The deepest visual level; deeper items render at this level but keep their real column.
    static let maximumDepth = 3
    /// Columns an item must be indented beyond its parent item to nest under it.
    static let nestingThreshold = 2
    private(set) var columns: [Int] = []

    /// Leading indentation in columns: a space counts 1, a tab advances to the next multiple of 4,
    /// and any other leading whitespace that `.whitespaces` trims counts 1.
    nonisolated static func indentColumns(_ raw: String) -> Int {
        var column = 0
        for scalar in raw.unicodeScalars {
            guard CharacterSet.whitespaces.contains(scalar) else { break }
            column = scalar == "\t" ? (column / 4 + 1) * 4 : column + 1
        }
        return column
    }

    /// A list item at `column`: pops every open item it does not nest under and returns its clamped depth.
    mutating func enterItem(column: Int) -> Int {
        while let top = columns.last, column < top + Self.nestingThreshold { columns.removeLast() }
        let depth = min(columns.count, Self.maximumDepth)
        columns.append(column)
        return depth
    }

    /// A non-blank, non-list line. Anything not indented under a top-level item ends the list.
    mutating func noteNonListLine(column: Int) {
        if column < Self.nestingThreshold { columns = [] }
    }
}
