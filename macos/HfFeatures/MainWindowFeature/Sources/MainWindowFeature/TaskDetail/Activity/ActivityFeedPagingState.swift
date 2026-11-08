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
import HfUI
import MonitorCore

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
    /// The feed's presentation style; part of the root inputs, so a change remeasures every row.
    var style = ActivityFeedStyle.standard
    var expandedGroups: Set<String>
    var tailPresentation: ActivityFeedTailPresentation
    var history: EventHistoryState
    var paginationRevision: Int
    var visible: Bool
    var loading: Bool
    var approvalReveal: CallerApprovalReveal?
    var activitySnapshot: ActivityFeedSnapshot?

    static func == (lhs: Self, rhs: Self) -> Bool {
        let rowsEqual: Bool = if let left = lhs.activitySnapshot, let right = rhs.activitySnapshot {
            left === right && lhs.shownRows.count == rhs.shownRows.count
                && lhs.shownRows.first?.id == rhs.shownRows.first?.id
        } else {
            lhs.shownRows == rhs.shownRows && lhs.allRowIDs == rhs.allRowIDs
        }
        return rowsEqual && lhs.start == rhs.start && lhs.emptyText == rhs.emptyText
            && lhs.horizontalPadding == rhs.horizontalPadding && lhs.showsPromptBubble == rhs.showsPromptBubble
            && lhs.style == rhs.style
            && lhs.expandedGroups == rhs.expandedGroups && lhs.tailPresentation == rhs.tailPresentation
            && lhs.history == rhs.history && lhs.paginationRevision == rhs.paginationRevision
            && lhs.visible == rhs.visible && lhs.loading == rhs.loading && lhs.approvalReveal == rhs.approvalReveal
    }
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
        let style = model.style
        let hasHeader = header != nil
        if let header { entries.append(.header(header)) }
        let showsEmpty = model.emptyText != nil && model.shownRows.isEmpty
        if showsEmpty, let emptyText = model.emptyText {
            entries.append(.empty(emptyText, topSpacing: style.spacing(
                first: !hasHeader, standardFirst: HfRadius.Metrics.spacing12, standardBetween: HfRadius.Metrics.spacing20)))
        }
        for row in model.shownRows {
            let isFirst = !hasHeader && !showsEmpty && row.id == model.shownRows.first?.id
            entries.append(.row(ActivityFeedNativeEntry.Row(
                row: row,
                isExpanded: isExpanded(row: row, expandedGroups: model.expandedGroups),
                fade: following && !mountedIDs.contains(row.id),
                topSpacing: style.spacing(first: isFirst, standardFirst: HfRadius.Metrics.spacing12,
                                          standardBetween: HfRadius.Metrics.spacing20)
            )))
        }
        if case .standard(let standard) = model.tailPresentation {
            for card in standard.approvals {
                entries.append(.approval(card, topSpacing: style.isTranscript
                    ? style.spacing(first: entries.isEmpty, standardFirst: 0, standardBetween: 0)
                    : HfRadius.Metrics.spacing12))
            }
        }
        let hasContent = hasHeader || showsEmpty || !model.shownRows.isEmpty || (style.isTranscript && !entries.isEmpty)
        let hasTail = hasTail(model)
        if hasTail {
            var tail = model.tailPresentation
            if case .standard(var standard) = tail {
                standard.approvals = []
                tail = .standard(standard)
            }
            entries.append(.tail(tail, topSpacing: style.spacing(
                first: !hasContent, standardFirst: HfRadius.Metrics.spacing12, standardBetween: HfRadius.Metrics.spacing20)))
        }
        entries.append(.bottom(topSpacing: 0))
        return entries
    }

    static func hasTail(_ model: ActivityFeedNativeModel) -> Bool {
        switch model.tailPresentation {
        case .absent: false
        case .plainText: true
        case .standard(let standard):
            standard.subTaskStrip != nil || !standard.pendingMessages.isEmpty
                || !standard.workMessages.isEmpty || standard.liveStep != nil || standard.approvalNotice != nil
        }
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

/// What one update does to the table. A tail insert removes a leading run of entries (a window
/// slide, with a lost "Beginning of activity" header) and inserts new rows ahead of the trailing
/// approvals, tail and bottom sentinel, leaving every other entry in place; a structural change
/// reloads the table and restores the reading position.
enum ActivityFeedNativePlan: Equatable {
    case unchanged
    /// `removeLeading` counts the leading table entries removed from the previous list, a lost
    /// header included. `insertAt` is the index, after that removal, of the first trailing
    /// non-row entry, where `count` entries of the next list are inserted.
    case tailInsert(removeLeading: Int, insertAt: Int, count: Int)
    case structural

    static func plan(previous: [ActivityFeedNativeEntry], next: [ActivityFeedNativeEntry]) -> Self {
        let previousIDs = previous.map(\.id)
        let nextIDs = next.map(\.id)
        // Same entry ids: the table's structure is untouched and only content refreshes.
        guard previousIDs != nextIDs else { return .unchanged }
        guard let old = Segments(previous), let new = Segments(next),
              old.trailing == new.trailing, !old.rowIDs.isEmpty, !new.rowIDs.isEmpty,
              let dropped = old.rowIDs.firstIndex(of: new.rowIDs[0]) else { return .structural }
        let kept = old.rowIDs.count - dropped
        guard new.rowIDs.count > kept, Array(old.rowIDs[dropped...]) == Array(new.rowIDs.prefix(kept)) else {
            return .structural
        }
        let leadingOK = if dropped == 0 {
            old.leading == new.leading && (old.leading.isEmpty || old.leading == [.beginning])
        } else {
            new.leading.isEmpty && (old.leading.isEmpty || old.leading == [.beginning])
        }
        guard leadingOK else { return .structural }
        let removeLeading = dropped == 0 ? 0 : old.leading.count + dropped
        return .tailInsert(removeLeading: removeLeading, insertAt: new.leading.count + kept,
                           count: new.rowIDs.count - kept)
    }

    /// An entry list split into leading headers, one contiguous run of rows and the trailing
    /// non-row entries. Rows are identified by their case, never by id.
    private struct Segments {
        var leading: [ActivityFeedNativeEntry.Header] = []
        var rowIDs: [String] = []
        var trailing: [String] = []

        init?(_ entries: [ActivityFeedNativeEntry]) {
            var inRun = false
            var finished = false
            for entry in entries {
                switch entry {
                case .row(let row):
                    guard !finished else { return nil }
                    inRun = true
                    rowIDs.append(row.row.id)
                case .header(let header) where !inRun && !finished:
                    leading.append(header)
                case .header:
                    return nil
                default:
                    finished = true
                    trailing.append(entry.id)
                }
            }
        }
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
        let ids = SummaryEntry.withoutSummaryIDs(model.allRowIDs)
        if ids != SummaryEntry.withoutSummaryIDs(requestedIDs), !isLiveAppend(ids) { return .rows }
        if model.history.isLoading { return nil }
        if observedLoading { return .settled }
        if model.history.error != history.error { return .settled }
        if model.history.hasMore != history.hasMore { return .settled }
        return nil
    }

    /// A pure live append — new rows at the newest end — keeps the request outstanding.
    private func isLiveAppend(_ ids: [String]) -> Bool {
        let requested = SummaryEntry.withoutSummaryIDs(requestedIDs)
        guard !requested.isEmpty else { return false }
        return ids.count >= requested.count && Array(ids.prefix(requested.count)) == requested
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
        case .single(let row, _): [row.id]
        case .toolGroup(let group): Set(group.members.map(\.id))
        case .summary(let entry): [entry.id]
        }
        return next.firstIndex { row in
            switch row {
            case .single(let value, _): members.contains(value.id)
            case .toolGroup(let group): group.members.contains { members.contains($0.id) }
            case .summary(let entry): members.contains(entry.id)
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
    /// The row that stands in for a reading whose row `id` leaves the list: the nearest surviving row before it in
    /// `old` (both in list order), else the nearest one after it. `nil` when `id` is not in `old` or nothing survives.
    static func neighbour(of id: String, old: [String], surviving: Set<String>) -> String? {
        guard let index = old.firstIndex(of: id) else { return nil }
        return old[..<index].last(where: surviving.contains) ?? old[(index + 1)...].first(where: surviving.contains)
    }

    static func anchor(index: Int, id: String, rowRect: CGRect, visibleMinY: CGFloat, shownIndex: Int)
        -> ParallelVerticalAnchor {
        ParallelVerticalAnchor(id: id, index: shownIndex, relativeOffset: rowRect.minY - visibleMinY)
    }

    static func restoredOffset(anchor: ParallelVerticalAnchor, resolvedIndex: Int, rowRect: CGRect) -> CGFloat {
        max(0, rowRect.minY - max(anchor.relativeOffset, -max(0, rowRect.height - 1)))
    }
}
