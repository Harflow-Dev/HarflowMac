//
//  ActivityFeedNativeArrival.swift
//  MainWindowFeature
//
//  Which feed rows fade in on arrival. The fade itself is a Core Animation animation on the
//  cell host's layer (`ActivityFeedNativeCell.playArrivalFade`); this file decides who plays it.
//

import AppKit

extension ActivityFeedNativeList.Coordinator {
    /// Records the rows this build adds while the feed follows live as pending arrivals, the only
    /// rows that fade in when their cell is first hosted. Rows added while the user reads above
    /// the tail never join, even after following resumes, and the next build made while not
    /// following clears the set. The set is pruned to the current entries so it stays bounded;
    /// mounting a row removes it (see `tableView(_:viewFor:row:)`).
    func notePendingArrivals(next: [ActivityFeedNativeEntry], following: Bool) {
        let nextIDs = Set(next.map(\.id))
        // Rows built while the reader is above the tail never fade, so a pause drops what had not
        // mounted yet, as the retired per-entry flag did.
        if !following { pendingArrivals.removeAll() }
        if following {
            let known = Set(entries.map(\.id))
            for entry in next {
                if case .row = entry, !known.contains(entry.id) { pendingArrivals.insert(entry.id) }
            }
        }
        pendingArrivals.formIntersection(nextIDs)
    }

    /// Whether `cell`, about to be configured for `entry`, plays the arrival fade: it gets a fresh
    /// host, the entry is a timeline row that arrived while following, and it has not mounted.
    func arrivalFades(entry: ActivityFeedNativeEntry, in cell: ActivityFeedNativeCell) -> Bool {
        guard case .row = entry else { return false }
        return (cell.entryID != entry.id || cell.host == nil)
            && pendingArrivals.contains(entry.id) && !mountedIDs.contains(entry.id)
    }
}
