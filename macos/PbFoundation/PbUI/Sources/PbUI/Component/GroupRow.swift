import MonitorCore
import SwiftUI

// MARK: - GroupRow

/// A parallel run as one row: overlapping backend dots, the group's name over "Parallel run · N of
/// M finished", a thin progress bar, and a spinner while any member is running. Takes only a plain
/// `ParallelGroup` value and never reads `AppModel`, so it qualifies for the shared component layer.
public struct GroupRow: View {
    public let group: ParallelGroup

    public init(group: ParallelGroup) {
        self.group = group
    }

    /// "Parallel run · N of M finished".
    public nonisolated static func subtitle(finished: Int, total: Int) -> String {
        "Parallel run · \(finished) of \(total) finished"
    }

    /// The fraction of members that finished, clamped to 0...1; 0 for an empty group.
    public nonisolated static func progress(finished: Int, total: Int) -> Double {
        total > 0 ? min(1, max(0, Double(finished) / Double(total))) : 0
    }

    public var body: some View {
        HStack(spacing: 8) {
            BackendDotStack(backends: group.conversations.prefix(3).map(\.first.backend))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                Text(Self.subtitle(finished: group.doneCount, total: group.total))
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                ProgressView(value: Self.progress(finished: group.doneCount, total: group.total))
                    .progressViewStyle(.linear)
                    .controlSize(.mini)
                    .tint(Color.runningFG)
            }
            Spacer(minLength: 4)
            if group.anyRunning { ProgressView().controlSize(.mini) }
        }
    }
}

#if DEBUG
#Preview("GroupRow - light") {
    GroupRowPreview().preferredColorScheme(.light)
}

#Preview("GroupRow - dark") {
    GroupRowPreview().preferredColorScheme(.dark)
}

private struct GroupRowPreview: View {
    var body: some View {
        // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
        // so the preview goes through the same public `Lineage.sections` entry point the app uses.
        let tasks = [
            TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"), "group": .string("release-notes")]))!,
            TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!
        ]
        GroupRow(group: Lineage.sections(tasks).parallel.first!)
            .padding()
            .frame(width: 280)
            .background(Color.sidebarBG)
    }
}
#endif
