import SwiftUI

// MARK: - ActivityFeedWindow

/// UI pages are independent of the bounded event reader's pages.
enum ActivityFeedWindow {
    static let pageSize = 100
    static let threshold: CGFloat = 200

    static func firstIndex(ids: [String], retainedID: String?) -> Int {
        retainedID.flatMap { ids.firstIndex(of: $0) } ?? max(0, ids.count - pageSize)
    }

    static func olderBoundary(ids: [String], retainedID: String?) -> String? {
        let first = firstIndex(ids: ids, retainedID: retainedID)
        guard first > 0 else { return nil }
        return ids[max(0, first - pageSize)]
    }

    static func shouldLoad(offset: CGFloat, viewport: CGFloat, eligibility: ActivityFeedEligibility) -> Bool {
        eligibility.positioned && !eligibility.restoring && eligibility.visible && !eligibility.loading
            && eligibility.error == nil && viewport > 0 && offset <= threshold
    }
}

/// Bounds automatic filling when collapsed or filtered pages do not grow the viewport.
struct ActivityShortFillBudget {
    private(set) var remaining = 1
    mutating func replenish() { remaining = 1 }
    mutating func consume(content: CGFloat, viewport: CGFloat) -> Bool {
        guard content <= viewport + 1 else { return true }
        guard remaining > 0 else { return false }
        remaining -= 1
        return true
    }
}

// MARK: - ActivityFeedEligibility

struct ActivityFeedEligibility {
    var positioned = false
    var restoring = false
    var visible = true
    var loading = false
    var error: String?
}
