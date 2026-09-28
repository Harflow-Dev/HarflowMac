import MonitorCore
import SwiftUI

/// Moved out of the app target's `SidebarView.swift` (Phase 2 package skeleton): it takes only a
/// plain `ParallelGroup` value and never reads `AppModel`, so it qualifies for the shared component
/// layer per the settled plan. Behaviour is unchanged.
public struct GroupRow: View {
    public let group: ParallelGroup
    
    public init(group: ParallelGroup) {
        self.group = group
    }
    
    public var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -4) {
                ForEach(group.conversations.prefix(3)) { BackendBadge(backend: $0.first.backend, size: 16) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.pb(.body, weight: .medium)).lineLimit(1)
                Text("\(group.doneCount) of \(group.total) done").font(.pb(.caption)).foregroundStyle(.secondary)
            }
            Spacer()
            if group.anyRunning { Circle().fill(Color.runningFG).frame(width: 6, height: 6) }
        }
    }
}

#if DEBUG
#Preview {
    // `ParallelGroup`/`TaskNode` have no public initializer (MonitorCore builds them internally),
    // so the preview goes through the same public `Lineage.sections` entry point the app uses.
    let tasks = [
        TaskInfo(.object(["task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"), "group": .string("release-notes")]))!,
        TaskInfo(.object(["task_id": .string("def456"), "backend": .string("codex"), "status": .string("completed"), "group": .string("release-notes")]))!
    ]
    let group = Lineage.sections(tasks).parallel.first!
    return GroupRow(group: group)
        .padding()
        .frame(width: 260)
}
#endif
