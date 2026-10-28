import HfUI
import MonitorCore
import SwiftUI

// MARK: - ParallelColumnUIState

/// Lightweight interaction state survives eviction of a conversation's activity view.
@Observable
@MainActor
final class ParallelColumnUIState {
    let disclosures = ActivityFeedDisclosures()
    let activityHandoff = SkeletonContentState()
    var expandedGroups: Set<String> = []
    @ObservationIgnored private var followState = FollowLiveScrollState()
    private var followsLive = true
    var followLive: FollowLiveScrollState {
        get { _ = followsLive; return followState }
        set {
            followState = newValue
            if followsLive != newValue.isFollowing { followsLive = newValue.isFollowing }
        }
    }

    var retainedFirstID: String?
    var recentFirstID: String?
    @ObservationIgnored var anchor: ParallelVerticalAnchor?
    @ObservationIgnored var scrollOffset: CGFloat = 0
    @ObservationIgnored var viewportPositioned = false
    @ObservationIgnored var activityMembers: Set<String> = []
    @ObservationIgnored var oldestSequences: [String: Int] = [:]
    @ObservationIgnored var paginationRevision = 0
    @ObservationIgnored var inventoryMembers: [String: TaskInfo] = [:]
    @ObservationIgnored var inventorySession: String?
    @ObservationIgnored var inventoryCursor: String?
    @ObservationIgnored var inventoryComplete = false
    @ObservationIgnored var inventoryIncomplete = false
    @ObservationIgnored var inventoryError: String?
}

// MARK: - ParallelVerticalAnchor

struct ParallelVerticalAnchor: Equatable {
    let id: String
    let index: Int
    let relativeOffset: CGFloat

    static func capture(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat = 0) -> Self? {
        var lower = 0
        var upper = ids.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            guard let frame = frames[ids[middle]] else {
                return captureMeasured(ids: ids, frames: frames, viewportHeight: viewportHeight, offset: offset)
            }
            if frame.maxY <= offset { lower = middle + 1 } else { upper = middle }
        }
        guard lower < ids.count, let frame = frames[ids[lower]],
              frame.minY < offset + viewportHeight else { return nil }
        return Self(id: ids[lower], index: lower, relativeOffset: frame.minY - offset)
    }

    private static func captureMeasured(ids: [String], frames: [String: CGRect], viewportHeight: CGFloat, offset: CGFloat) -> Self? {
        let visible = frames.filter { $0.value.maxY > offset && $0.value.minY < offset + viewportHeight }
        guard let first = visible.min(by: { $0.value.minY < $1.value.minY }),
              let index = ids.firstIndex(of: first.key) else { return nil }
        return Self(id: first.key, index: index, relativeOffset: first.value.minY - offset)
    }

    func offset(in frame: CGRect) -> CGFloat {
        // Reflow can shorten a row past its saved intra-row reading position.
        // Keep that row visible rather than restoring an offset inside its successor.
        max(0, frame.minY - max(relativeOffset, -max(0, frame.height - 1)))
    }

    func resolvedID(in ids: [String]) -> String? {
        if ids.contains(id) { return id }
        guard !ids.isEmpty else { return nil }
        return ids[min(index, ids.count - 1)]
    }
}

// MARK: - ParallelViewportPosition

/// Coordinator-retained pixel position, independent of lane membership and native mounts.
@MainActor
final class ParallelViewportPosition {
    var offset: CGFloat = 0
}
