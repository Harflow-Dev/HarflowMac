import SwiftUI

// MARK: - ActivityFeedDisclosures

/// Lightweight disclosure values outlive recycled native cells without retaining their view graphs.
@Observable @MainActor final class ActivityFeedDisclosures {
    var expandedTools: Set<String> = []
    var expandedPrompts: Set<String> = []
}

struct ActivityFeedDisclosureContext {
    let state: ActivityFeedDisclosures
    let rowID: String
    let taskID: String
}

extension EnvironmentValues {
    @Entry var activityFeedDisclosure: ActivityFeedDisclosureContext?
}
