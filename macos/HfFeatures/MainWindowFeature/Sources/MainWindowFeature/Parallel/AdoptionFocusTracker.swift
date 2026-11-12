//
//  AdoptionFocusTracker.swift
//  MainWindowFeature
//
//  After "Load current activity" the lane head takes focus once the notice clears. A notice that is replaced by
//  another one means adoption did not complete, so the pending request ends without moving focus.
//

import Foundation

// MARK: - AdoptionFocusTracker

struct AdoptionFocusTracker: Equatable {
    enum Result: Equatable {
        /// Adoption completed: move focus to the head and announce it.
        case loaded
        /// The notice changed to another notice: the request is over, focus stays.
        case failed
        /// Nothing to do.
        case none
    }

    private(set) var isAwaiting = false

    mutating func requestAdoption() { isAwaiting = true }

    mutating func noticeChanged(from old: String?, to new: String?) -> Result {
        guard isAwaiting else { return .none }
        if new == nil {
            isAwaiting = false
            return .loaded
        }
        if new != old {
            isAwaiting = false
            return .failed
        }
        return .none
    }

    /// The request ends without a result (the lane left the screen, or adoption became unavailable).
    mutating func cancel() { isAwaiting = false }
}
