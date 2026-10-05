import MonitorCore
import SwiftUI

// MARK: - GroupRow

/// A parallel run as one row: overlapping backend dots, the group's name over "Parallel run · N of
/// M finished", a thin progress bar while any member is running, and a spinner alongside it. Takes only a plain
/// `ParallelGroup` value and never reads `AppModel`, so it qualifies for the shared component layer.
public struct GroupRow: View {
    public let group: ParallelGroup
    private let conversations: [Conversation]
    @Environment(\.backgroundProminence) private var prominence

    /// Accepts the screen's actual-session projection while preserving ordinary group rendering by default.
    public init(group: ParallelGroup, conversations: [Conversation]? = nil) {
        self.group = group
        self.conversations = conversations ?? group.conversations
    }

    private var total: Int { conversations.count }
    private var doneCount: Int { conversations.filter(\.current.status.isTerminal).count }

    /// "Parallel run · N of M finished" — or, for a group of one, "Group · <status>", since a
    /// single member is not a parallel run.
    public nonisolated static func subtitle(finished: Int, total: Int, singleMemberStatus: TaskStatus? = nil) -> String {
        if total == 1, let singleMemberStatus { return "Group · \(singleMemberStatus.label)" }
        return "Parallel run · \(finished) of \(total) finished"
    }

    /// The fraction of members that finished, clamped to 0...1; 0 for an empty group.
    public nonisolated static func progress(finished: Int, total: Int) -> Double {
        total > 0 ? min(1, max(0, Double(finished) / Double(total))) : 0
    }

    /// The bar only tracks a run in flight; a finished group shows none.
    public nonisolated static func showsProgress(anyRunning: Bool) -> Bool {
        anyRunning
    }

    public var body: some View {
        HStack(spacing: 8) {
            BackendDotStack(backends: conversations.prefix(3).map(\.first.backend))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                Text(Self.subtitle(finished: doneCount, total: total, singleMemberStatus: conversations.first?.current.status))
                    .font(.pb(.caption))
                    .foregroundStyle(Color.secondaryText(on: prominence))
                    .lineLimit(1)
                if Self.showsProgress(anyRunning: group.anyRunning) {
                    ProgressView(value: Self.progress(finished: doneCount, total: total))
                        .progressViewStyle(.linear)
                        .controlSize(.mini)
                        .tint(prominence == .increased ? Color.white : Color.runningFG)
                }
            }
            Spacer(minLength: 4)
            if group.anyRunning { RunningSpinner(tint: prominence == .increased ? .white : nil) }
        }
        .padding(.vertical, 6)
    }
}

#if DEBUG
#Preview("GroupRow - light") {
    GroupRowPreview().preferredColorScheme(.light)
}

#Preview("GroupRow - dark") {
    GroupRowPreview().preferredColorScheme(.dark)
}

#Preview("GroupRow finished - light") {
    GroupRowPreview(finished: true).preferredColorScheme(.light)
}

#Preview("GroupRow finished - dark") {
    GroupRowPreview(finished: true).preferredColorScheme(.dark)
}

private struct GroupRowPreview: View {
    var finished = false

    var body: some View {
        // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
        // so the preview goes through the same public `Lineage.sections` entry point the app uses.
        let tasks = [
            TaskInfo(.object([
                "task_id": .string("abc123"), "backend": .string("claude"), "status": .string(finished ? "completed" : "running"),
                "group": .string("release-notes")
            ]))!,
            TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!
        ]
        GroupRow(group: Lineage.sections(tasks).parallel.first!)
            .padding()
            .frame(width: 280)
            .background(Color.sidebarBG)
    }
}
#endif
