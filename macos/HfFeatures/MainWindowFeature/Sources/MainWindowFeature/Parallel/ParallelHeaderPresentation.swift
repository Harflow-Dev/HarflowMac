import HfUI
import MonitorCore

// MARK: - ParallelHeaderPresentation

/// Pure top bar values from complete current membership, independent of activity residency.
struct ParallelHeaderPresentation: Equatable {
    let statusSummary: String?
    let counts: ParallelStatusCounts
    /// The enforcement sentence: the common claim when every agent makes it, else `fallback`; `nil` for no members.
    let meta: String?

    init(tasks: [TaskInfo], fallback: String) {
        self.counts = ParallelStatusCounts(tasks: tasks)
        self.statusSummary = counts.text
        self.meta = tasks.isEmpty ? nil : (EnforcementText.common(tasks) ?? fallback)
    }

    /// The group's top bar content for `title`.
    func content(title: String) -> GroupTopBarContent {
        GroupTopBarContent(title: title, badge: TaskBadgeModel.group(counts), meta: meta)
    }
}
