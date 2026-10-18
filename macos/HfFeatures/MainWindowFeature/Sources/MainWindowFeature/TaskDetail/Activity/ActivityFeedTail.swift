import Foundation
import MonitorCore

// MARK: - ActivityFeedTail

struct ActivityFeedTail: Equatable {
    var liveStep: LiveStep?
    var pendingMessages: [PendingMessage] = []
    var children: [TaskDetailTimelineChild] = []
}

/// Concrete tail rendering inputs; callbacks are delivered separately through the feed relay.
enum ActivityFeedTailPresentation: Equatable {
    case absent
    case standard(Standard)
    case plainText(String)

    struct Standard: Equatable {
        var subTaskStrip: Strip?
        var pendingMessages: [PendingMessage] = []
        var liveStep: Line?
    }

    struct Strip: Equatable {
        let children: [TaskDetailTimelineChild]
        let start: Date?
    }

    struct Line: Equatable {
        enum Indicator: Equatable { case singleDot, threeDots }
        let text: String
        let indicator: Indicator
    }

    func isVisible(with semanticTail: ActivityFeedTail) -> Bool {
        semanticTail != ActivityFeedTail() && self != .absent
    }
}
