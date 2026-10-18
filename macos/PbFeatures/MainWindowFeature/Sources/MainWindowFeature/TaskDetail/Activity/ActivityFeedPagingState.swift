//
//  ActivityFeedPagingState.swift
//  MainWindowFeature
//
//  The native feed's pure planning layer: the immutable input model, the entry builder that maps
//  it onto the table's entries with the feed's established spacing, the older-page request state
//  (one outstanding request, commit-on-publication, stale rejection), the entry-diff plan, and
//  the reading-anchor transfer that survives regrouping. No AppKit, no side effects — the
//  coordinator owns every mutation.
//

import Foundation
import MonitorCore
import PbUI

// MARK: - ActivityFeedNativeModel

/// The feed's immutable inputs for one update. `shownRows` is the already-windowed row list (the
/// latest `ActivityFeedWindow.pageSize` rows, or everything from `retainedFirstID`); `allRowIDs`
/// is the full conversation's row ids, which paging needs to reveal retained rows and reject
/// stale repeated requests.
struct ActivityFeedNativeModel: Equatable {
    var shownRows: [ActivityRow]
    var allRowIDs: [String]
    var start: Date?
    var emptyText: String?
    var horizontalPadding: CGFloat
    var showsPromptBubble: Bool
    var expandedGroups: Set<String>
    var tailPresentation: ActivityFeedTailPresentation
    var history: EventHistoryState
    var paginationRevision: Int
    var visible: Bool
    var loading: Bool
}

// MARK: - ActivityFeedNativeEntries

/// Builds the table's entries from the model. The spacing rules are the feed's established
/// presentation: 12pt before the first content, 20pt between content sections and rows, a
/// hairline sentinel with 12pt of closing space at the bottom.
enum ActivityFeedNativeEntries {
    static func resolveHeader(history: EventHistoryState, showsBeginning: Bool, pendingPage: Bool)
        -> ActivityFeedNativeEntry.Header? {
        if history.isLoading || pendingPage { return .loading }
        if let error = history.error { return .error(error) }
        if showsBeginning { return .beginning }
        return nil
    }

    static func build(model: ActivityFeedNativeModel, header: ActivityFeedNativeEntry.Header?, following: Bool,
                      mountedIDs: Set<String>) -> [ActivityFeedNativeEntry] {
        var entries: [ActivityFeedNativeEntry] = []
        let hasHeader = header != nil
        if let header { entries.append(.header(header)) }
        let showsEmpty = model.emptyText != nil && model.shownRows.isEmpty
        if showsEmpty, let emptyText = model.emptyText {
            entries.append(.empty(emptyText, topSpacing: hasHeader ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12))
        }
        let rowTop = PbRadius.Metrics.spacing20
        for row in model.shownRows {
            let isFirst = !hasHeader && !showsEmpty && row.id == model.shownRows.first?.id
            entries.append(.row(ActivityFeedNativeEntry.Row(
                row: row,
                isExpanded: isExpanded(row: row, expandedGroups: model.expandedGroups),
                fade: following && !mountedIDs.contains(row.id),
                topSpacing: isFirst ? PbRadius.Metrics.spacing12 : rowTop
            )))
        }
        let hasContent = hasHeader || showsEmpty || !model.shownRows.isEmpty
        let hasTail = hasTail(model)
        if hasTail {
            entries.append(.tail(model.tailPresentation,
                                  topSpacing: hasContent ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12))
        }
        entries.append(.bottom(topSpacing: (hasContent || hasTail) ? PbRadius.Metrics.spacing20 : PbRadius.Metrics.spacing12))
        return entries
    }

    static func hasTail(_ model: ActivityFeedNativeModel) -> Bool {
        if case .absent = model.tailPresentation { return false }
        return true
    }

    static func isExpanded(row: ActivityRow, expandedGroups: Set<String>) -> Bool {
        if case .toolGroup(let group) = row { return expandedGroups.contains(group.id) }
        return false
    }

    /// True when the feed shows the "Beginning of activity" marker: history is exhausted and the
    /// window starts at the conversation's first row.
    static func showsBeginning(allRowIDs: [String], shownRows: [ActivityRow], retainedFirstID: String?,
                               history: EventHistoryState) -> Bool {
        guard !history.isLoading, history.error == nil, !shownRows.isEmpty,
              ActivityFeedWindow.firstIndex(ids: allRowIDs, retainedID: retainedFirstID) == 0 else { return false }
        return !history.hasMore
    }
}

// MARK: - ActivityFeedNativePlan

/// What one update does to the table. A pure append only notes the new row count (no existing
/// row is touched); a structural change reloads the table and restores the reading position.
enum ActivityFeedNativePlan: Equatable {
    case unchanged
    case append
    case structural

    static func plan(previous: [ActivityFeedNativeEntry], next: [ActivityFeedNativeEntry]) -> Self {
        let previousIDs = previous.map(\.id)
        let nextIDs = next.map(\.id)
        // Same entry ids: the table's structure is untouched and only content refreshes.
        guard previousIDs != nextIDs else { return .unchanged }
        // Pure bottom append: the previous entries are exactly next's prefix.
        guard !previous.isEmpty, nextIDs.count > previousIDs.count,
              Array(nextIDs.prefix(previousIDs.count)) == previousIDs else { return .structural }
        return .append
    }
}

// MARK: - ActivityFeedNativePendingPage

/// One accepted older-page request. The request stays outstanding until the corresponding
/// snapshot commits — the loader's `loading` publication alone never commits it, and a pure
/// live append never does either — so an accepted request is never superseded by a second
/// while the first is still in flight.
struct ActivityFeedNativePendingPage: Equatable {
    let requestedIDs: [String]
    let history: EventHistoryState
    let paginationRevision: Int

    enum Commit: Equatable {
        /// The corresponding older rows committed: ids the request did not cover arrived.
        case rows
        /// The loader finished without those rows: an error, exhaustion or revision
        /// publication ends the request cycle without revealing anything.
        case settled
    }

    /// Commit evidence, evaluated against the model the coordinator is about to install.
    /// `observedLoading` is the loader's own `loading` publication seen since the request.
    func commit(by model: ActivityFeedNativeModel, observedLoading: Bool) -> Commit? {
        if model.paginationRevision != paginationRevision { return .settled }
        if model.allRowIDs != requestedIDs, !isLiveAppend(model.allRowIDs) { return .rows }
        if model.history.isLoading { return nil }
        if observedLoading { return .settled }
        if model.history.error != history.error { return .settled }
        if model.history.hasMore != history.hasMore { return .settled }
        return nil
    }

    /// A pure live append — new rows at the newest end — keeps the request outstanding.
    private func isLiveAppend(_ ids: [String]) -> Bool {
        guard !requestedIDs.isEmpty else { return false }
        return ids.count >= requestedIDs.count && Array(ids.prefix(requestedIDs.count)) == requestedIDs
    }
}

// MARK: - ActivityFeedNativeRegroup

/// Transfers the reading anchor, the retained boundary and disclosure state across regrouping,
/// by overlapping member ids: when a row id disappears because tool calls were regrouped into
/// a different card, the new card that contains any of the old row's members inherits its
/// position and state. The boundary and disclosure transfer run independently of the anchor —
/// a regroup can consume the retained boundary's row or an expanded group while the anchor row
/// itself survives.
enum ActivityFeedNativeRegroup {
    static func transfer(anchor: ParallelVerticalAnchor, old: [ActivityRow], next: [ActivityRow],
                         retainedFirstID: inout String?, expandedGroups: inout Set<String>) -> ParallelVerticalAnchor? {
        guard !next.contains(where: { $0.id == anchor.id }),
              let index = replacementIndex(for: anchor.id, in: old, next: next) else { return nil }
        let replacement = next[index].id
        if retainedFirstID == anchor.id { retainedFirstID = replacement }
        if expandedGroups.remove(anchor.id) != nil { expandedGroups.insert(replacement) }
        return ParallelVerticalAnchor(id: replacement, index: index, relativeOffset: anchor.relativeOffset)
    }

    /// Moves the retained reveal boundary to the card that absorbed its row, so the window
    /// keeps revealing the older rows it had already revealed instead of falling back to the
    /// latest page and dropping them.
    static func transferBoundary(retainedFirstID: inout String?, old: [ActivityRow], next: [ActivityRow]) {
        guard let retained = retainedFirstID,
              !next.contains(where: { $0.id == retained }),
              let index = replacementIndex(for: retained, in: old, next: next) else { return }
        retainedFirstID = next[index].id
    }

    /// Moves every vanished expanded group's disclosure to the card that absorbed its members.
    static func transferDisclosures(expandedGroups: inout Set<String>, old: [ActivityRow], next: [ActivityRow]) {
        for id in expandedGroups where !next.contains(where: { $0.id == id }) {
            guard let index = replacementIndex(for: id, in: old, next: next) else { continue }
            expandedGroups.remove(id)
            expandedGroups.insert(next[index].id)
        }
    }

    /// The next row that shares any member with the old row the vanished id named.
    private static func replacementIndex(for id: String, in old: [ActivityRow], next: [ActivityRow]) -> Int? {
        guard let oldRow = old.first(where: { $0.id == id }) else { return nil }
        let members: Set<String> = switch oldRow {
        case .single(let row): [row.id]
        case .toolGroup(let group): Set(group.members.map(\.id))
        }
        return next.firstIndex { row in
            switch row {
            case .single(let value): members.contains(value.id)
            case .toolGroup(let group): group.members.contains { members.contains($0.id) }
            }
        }
    }
}

// MARK: - ActivityFeedNativeReading

/// Pure reading-anchor geometry against the table's row rects. The anchor names the first
/// visible semantic row and its intra-row offset; restoration keeps that row's top at the same
/// distance from the viewport top, clamped so a shrunken row still keeps positive content
/// visible (the same clamp `ParallelVerticalAnchor.offset(in:)` applies).
enum ActivityFeedNativeReading {
    static func anchor(index: Int, id: String, rowRect: CGRect, visibleMinY: CGFloat, shownIndex: Int)
        -> ParallelVerticalAnchor {
        ParallelVerticalAnchor(id: id, index: shownIndex, relativeOffset: rowRect.minY - visibleMinY)
    }

    static func restoredOffset(anchor: ParallelVerticalAnchor, resolvedIndex: Int, rowRect: CGRect) -> CGFloat {
        max(0, rowRect.minY - max(anchor.relativeOffset, -max(0, rowRect.height - 1)))
    }
}
