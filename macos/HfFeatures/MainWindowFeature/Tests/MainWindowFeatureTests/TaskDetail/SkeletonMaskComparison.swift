import Foundation

// MARK: - SkeletonMaskComparison

/// Compares a sampled skeleton mask with the recorded base mask, row by row. A row is a string of "#" (ink) and "."
/// (background) at a 20 pt grid.
///
/// The base was read from an anti-aliased bitmap with a pixel threshold, while the current mask reads layer-drawn
/// indicators geometrically (`ComposerMeasure.layerInk`). A grid point within half a pixel of a bar's end can therefore
/// land on either side. The comparison absorbs exactly that and nothing else: per row, at most one grid point may differ,
/// and it must sit at the end of a bar run (the run's last point added or missing, or the same at its start). Any other
/// difference fails: two or more points in a row, a flip inside a run or between two runs, a shifted bar, a run added
/// or removed, a different number of rows or a different row width.
enum SkeletonMaskComparison {
    /// Whether every row of `now` equals the same row of `base`, allowing the single end-of-run flip described above.
    static func rowsMatch(now: [String], base: [String]) -> Bool {
        mismatchedRows(now: now, base: base).isEmpty
    }

    /// The indices of the rows that are neither equal nor a single end-of-run flip; every row of the longer mask when the
    /// counts differ, so a missing or an extra row is never absorbed.
    static func mismatchedRows(now: [String], base: [String]) -> [Int] {
        guard now.count == base.count else { return Array(0 ..< max(now.count, base.count)) }
        return zip(now, base).enumerated().filter { !rowMatches(now: $1.0, base: $1.1) }.map(\.offset)
    }

    private static func rowMatches(now: String, base: String) -> Bool {
        if now == base { return true }
        let current = Array(now)
        let recorded = Array(base)
        guard current.count == recorded.count else { return false }
        let differing = recorded.indices.filter { current[$0] != recorded[$0] }
        guard differing.count == 1, let index = differing.first else { return false }
        // Judged against the recorded row: the flipped point must touch exactly one recorded ink point. Added next to
        // one run it extends it; removed from a run's end it retracts it. Touching none would add or remove a whole
        // run; touching two would join two runs or split one.
        let touching = [index - 1, index + 1].filter { recorded.indices.contains($0) && recorded[$0] == "#" }.count
        return touching == 1
    }
}
