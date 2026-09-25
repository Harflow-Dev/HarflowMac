import MonitorCore
import SwiftUI

/// One column per top-level member of a `group`. The final summary is rendered as the agent wrote
/// it (markdown); nothing is classified or tagged by the app.
struct ParallelView: View {
    @EnvironmentObject var model: AppModel
    let name: String
    @State private var confirmCancelAll = false
    @State private var showPrompt = false

    var body: some View {
        let group = Lineage.sections(model.tasks).parallel.first { $0.name == name }
        let members = group?.members.map(\.task) ?? []
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 16, weight: .semibold))
                    let freedoms = Set(members.compactMap(\.freedom)).sorted().joined(separator: ", ")
                    let repos = Set(members.map { Format.repo($0.repoPath) }).sorted().joined(separator: ", ")
                    Text("\(members.count) agents · \(freedoms) · \(repos)" + (group?.startedAt.map { " · started \(Format.time($0))" } ?? ""))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("View prompt") { showPrompt.toggle() }
                if members.contains(where: { $0.status.isRunning }) {
                    Button("Cancel all", role: .destructive) { confirmCancelAll = true }
                }
            }
            .padding(14)
            Divider()
            if members.isEmpty {
                Text("No tasks in this group any more.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(members) { member in
                            EventScope(taskID: member.taskID) { store in
                                ParallelColumn(task: model.task(member.taskID) ?? member, store: store, showPrompt: showPrompt)
                            }
                            .frame(width: max(360, 900 / CGFloat(max(1, members.count))))
                            Divider()
                        }
                    }
                }
            }
            Divider()
            HStack {
                Text(EnforcementText.common(members.map { model.snapshots[$0.taskID] ?? $0 }) ?? "Enforcement differs between these agents; see each task's details.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)
        }
        .confirmationDialog("Cancel every running task in this group?", isPresented: $confirmCancelAll, titleVisibility: .visible) {
            Button("Cancel all", role: .destructive) { model.cancelAll(members.filter { $0.status.isRunning }.map(\.taskID)) }
        }
    }
}

struct ParallelColumn: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    @ObservedObject var store: EventStore
    let showPrompt: Bool
    @State private var showAll = false
    @State private var confirmTakeover = false

    var body: some View {
        let items = store.items
        let shown = showAll ? items : Array(items.suffix(6))
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                BackendBadge(backend: task.backend, size: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.title(task.taskID)).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                    Text([task.backend, task.reasoningEffort.map { "effort \($0)" }, task.sessionID.map { "session \($0.prefix(8))" }].compactMap { $0 }.joined(separator: " · "))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                StatusPill(task: task, drivenByUser: model.session(forTask: task.taskID).map { !$0.ended } ?? false)
            }
            HStack {
                Button(task.status.isRunning ? "Take over" : "Continue in terminal") { confirmTakeover = true }
                    .disabled(task.sessionID == nil || model.busy.contains(task.taskID))
                Button("Open task") { model.selection = .task(task.taskID) }.buttonStyle(.link)
            }
            .font(.system(size: 11))
            if let message = model.messages[task.taskID] {
                Text(message).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if showPrompt, let prompt = store.prompt {
                Text(prompt).font(.system(size: 11, design: .monospaced)).lineLimit(12).textSelection(.enabled)
                    .padding(6).background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF5F5F7)))
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(shown) { item in
                        TimelineRow(item: item, start: task.startedAt, live: task.status.isRunning)
                    }
                    if items.count > shown.count {
                        Button("Show all \(items.count) steps") { showAll = true }.buttonStyle(.link).font(.system(size: 11))
                    }
                    Divider()
                    if task.status.isTerminal {
                        SectionLabel(text: "Final summary")
                        if let summary = model.snapshots[task.taskID]?.summary, !summary.isEmpty {
                            MarkdownText(text: summary)
                        } else {
                            Text("No summary was reported.").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Still working… the final summary shows here when \(task.backend) finishes.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 12)
            }
        }
        .padding(12)
        .confirmationDialog(task.status.isRunning ? "Take over this task?" : "Continue this session in a terminal?", isPresented: $confirmTakeover, titleVisibility: .visible) {
            Button(task.status.isRunning ? "Stop it and take over" : "Continue in terminal") {
                model.takeover(task.taskID, to: .embedded)
                // The terminal lives in the task's own view.
                model.selection = .task(task.taskID)
            }
        } message: {
            Text("The headless run is stopped first if it is still going. The terminal runs under your own default permissions, not \(task.freedom ?? "this task's freedom").")
        }
    }
}
