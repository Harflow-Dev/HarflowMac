import MonitorCore
import PbUI

// MARK: - ParallelHeaderPresentation

/// Pure header values from complete current membership, independent of activity residency.
struct ParallelHeaderPresentation {
    let statusSummary: String?
    let pills: [String]
    let caption: String

    init(tasks: [TaskInfo], fallback: String) {
        self.statusSummary = ParallelStatusSummary.text(tasks)
        let claims = EnforcementText.commonLines(tasks)
        self.pills = EnforcementText.pillLabels(fromCommonLines: claims)
        if pills.isEmpty {
            self.caption = EnforcementText.common(tasks) ?? fallback
        } else {
            let remaining = EnforcementText.captionLines(fromCommonLines: claims)
            self.caption = remaining.isEmpty ? "" : remaining.joined(separator: "; ") + "."
        }
    }
}
