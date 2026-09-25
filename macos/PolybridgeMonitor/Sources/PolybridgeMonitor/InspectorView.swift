import MonitorCore
import SwiftUI

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    @ObservedObject var store: EventStore
    let changes: GitChanges?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if task.status.isRunning {
                    section("Now") {
                        if let current = store.current, case .tool(let call, _) = current.body {
                            Text(call.tool).font(.system(size: 12, weight: .medium))
                            Text(call.headline).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(3)
                            if let at = current.at {
                                TimelineView(.periodic(from: .now, by: 1)) { context in
                                    Text("\(Format.clock(context.date.timeIntervalSince(at))) · step \(store.items.count)").font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                                }
                            }
                        } else {
                            Text("Thinking or writing").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                }
                section("Files changed") {
                    if let changes {
                        if changes.files.isEmpty { Text("None").font(.system(size: 12)).foregroundStyle(.secondary) }
                        ForEach(changes.files.prefix(12)) { file in
                            HStack(spacing: 6) {
                                Text(file.isUntracked ? "A" : file.status).font(.system(size: 10, weight: .bold, design: .monospaced)).frame(width: 12)
                                Text((file.path as NSString).lastPathComponent).font(.system(size: 11)).lineLimit(1)
                                Spacer()
                                if let added = file.added, let removed = file.removed {
                                    Text("+\(added)−\(removed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("From git in the repo, not the agent's report").font(.system(size: 10)).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                section("Activity") {
                    let activity = store.activity
                    let subtasks = Lineage.children(of: task.taskID, in: model.tasks).count
                    Text("\(activity.toolCalls) tool calls · \(activity.edits) edits · \(activity.commands) commands · \(subtasks) sub-tasks")
                        .font(.system(size: 11))
                }
                if !task.isRoot { lineage }
                section("Details") { details }
                if !task.notices.isEmpty {
                    section("Notices") {
                        ForEach(Array(task.notices.enumerated()), id: \.offset) { _, notice in
                            Text(notice).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .padding(14)
        }
        .background(Color(hex: 0xFBFBFC))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            content()
        }
    }

    private var lineage: some View {
        let ancestors = Lineage.ancestors(of: task.taskID, in: model.tasks)
        let parent = ancestors.last
        let siblings = parent.map { Lineage.children(of: $0.taskID, in: model.tasks) } ?? []
        return VStack(alignment: .leading, spacing: 16) {
            section("Lineage") {
                ForEach(Array(ancestors.enumerated()), id: \.element.id) { index, ancestor in
                    lineageRow(ancestor, indent: index)
                }
                ForEach(siblings) { sibling in
                    lineageRow(sibling, indent: ancestors.count, current: sibling.taskID == task.taskID)
                }
            }
            section("Limits from parent") {
                if let parent {
                    limit("Freedom", task.freedom ?? "—", "Parent is \(parent.freedom ?? "unknown"). polybridge refuses a sub-task that is less strict than its caller.")
                }
                if let maxDepth = task.maxDepth {
                    let left = maxDepth - task.depth
                    limit("Depth", "\(task.depth) of \(maxDepth)", left > 0 ? "This task can start \(left) more level\(left == 1 ? "" : "s") of sub-tasks." : "This task cannot start sub-tasks of its own.")
                }
                limit("Cancels with parent", "yes", "Cancelling the parent stops this task too (cascade cancel).")
            }
        }
    }

    private func lineageRow(_ info: TaskInfo, indent: Int, current: Bool = false) -> some View {
        Button {
            model.selection = .task(info.taskID)
        } label: {
            HStack(spacing: 6) {
                BackendBadge(backend: info.backend, size: 16)
                Text(model.title(info.taskID)).font(.system(size: 11, weight: current ? .semibold : .regular)).lineLimit(1)
                Spacer()
                Text("depth \(info.depth)").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.leading, CGFloat(indent) * 10)
        }
        .buttonStyle(.plain)
        .disabled(current)
    }

    private func limit(_ name: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack { Text(name).font(.system(size: 11, weight: .medium)); Spacer(); Text(value).font(.system(size: 11)) }
            Text(note).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var details: some View {
        let detail = model.snapshots[task.taskID] ?? task
        detailRow("Task", task.taskID)
        detailRow("Backend", [task.backend, detail.model, detail.reasoningEffort.map { "effort \($0)" }].compactMap { $0 }.joined(separator: " · "))
        detailRow("Freedom", task.freedom ?? "—")
        if let branch = changes?.branch { detailRow("Branch", branch) }
        detailRow("Started", Format.time(task.startedAt) + (task.isRoot ? " · root task" : ""))
        if let maxDepth = task.maxDepth { detailRow("Depth", "\(task.depth) of \(maxDepth)") }
        if let parent = task.spawnedBy { detailRow("Parent", parent) }
        if let root = task.rootTaskID, root != task.taskID { detailRow("Root", root) }
        if let group = task.group { detailRow("Group", group) }
        if let resumed = task.parentTaskID { detailRow("Resumed from", resumed) }
        if let session = task.sessionID { detailRow("Session", session) }
        if let detected = task.lineageDetected { detailRow("Caller found by", detected) }
        if let cost = detail.totalCostUSD { detailRow("Cost", String(format: "$%.4f", cost)) }
        ForEach(EnforcementText.lines(detail.enforcement), id: \.self) { line in
            Text(line).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        if detail.enforcement == nil, model.snapshots[task.taskID] != nil {
            Text("Enforcement was not recorded for this task.").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func detailRow(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 84, alignment: .leading)
            Text(value).font(.system(size: 11)).textSelection(.enabled).lineLimit(3)
        }
    }
}

/// Plain sentences for what polybridge reports as enforced. Each boolean in `enforcement` is a
/// strict claim, so a line is shown only when the claim is True — never inferred from `freedom`.
enum EnforcementText {
    static func lines(_ enforcement: [String: JSONValue]?) -> [String] {
        guard let enforcement else { return [] }
        var lines: [String] = []
        if enforcement["os_enforced"]?.boolValue == true { lines.append("Restrictions enforced by the OS sandbox") }
        if enforcement["writes_confined"]?.boolValue == true { lines.append("File writes confined to the workspace (+ temp dirs)") }
        if enforcement["commit_push_blocked"]?.boolValue == true {
            lines.append("Git commit and push blocked")
        } else if enforcement["direct_commit_commands_denied"]?.boolValue == true {
            lines.append("Direct git commit/push commands denied (not a full block)")
        }
        if enforcement["publish_attempts_allowed_by_polybridge"]?.boolValue == true { lines.append("Allowed to attempt commit/push/PR") }
        if let network = enforcement["network_access"]?.stringValue { lines.append("Network: \(network.replacingOccurrences(of: "_", with: " "))") }
        return lines
    }

    /// The Parallel view footer: only what every member's enforcement actually says.
    static func common(_ tasks: [TaskInfo]) -> String? {
        let sets = tasks.map { Set(lines($0.enforcement)) }
        guard let first = sets.first, sets.count == tasks.count, !tasks.isEmpty else { return nil }
        let shared = sets.dropFirst().reduce(first) { $0.intersection($1) }
        guard !shared.isEmpty else { return nil }
        return "Enforced for every agent here: " + shared.sorted().joined(separator: "; ") + "."
    }
}
