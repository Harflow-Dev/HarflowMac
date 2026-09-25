import MonitorCore
import SwiftUI

enum TaskTab: String, CaseIterable, Identifiable {
    case timeline = "Timeline", changes = "Changes", prompt = "Prompt", raw = "Raw events", terminal = "Terminal"
    var id: String { rawValue }
}

/// Holds one task's live events while the view is on screen.
struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    let taskID: String

    var body: some View {
        EventScope(taskID: taskID) { store in
            TaskDetailContent(taskID: taskID, store: store)
        }
        .id(taskID)
    }
}

/// Acquire a task's `EventStore` for as long as this view exists, then release it — so only tasks
/// on screen are tailed.
struct EventScope<Content: View>: View {
    @EnvironmentObject var model: AppModel
    let taskID: String
    @ViewBuilder let content: (EventStore) -> Content
    @State private var store: EventStore?

    var body: some View {
        Group {
            if let store { content(store) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
        .onAppear { if store == nil { store = model.acquireEvents(taskID) } }
        .onDisappear {
            if store != nil { model.releaseEvents(taskID) }
            store = nil
        }
    }
}

struct TaskDetailContent: View {
    @EnvironmentObject var model: AppModel
    let taskID: String
    @ObservedObject var store: EventStore
    @State private var tab: TaskTab = .timeline
    @State private var changes: GitChanges?
    @State private var changesError: String?
    @State private var confirmTakeover: AppModel.Destination?
    @State private var confirmCancel = false

    var body: some View {
        if let task = model.detail(taskID) {
            let session = model.session(forTask: taskID)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    header(task, session: session)
                    Divider()
                    tabBar(task, session: session)
                    Divider()
                    content(task, session: session)
                    if tab != .terminal {
                        Divider()
                        MessageBox(task: task)
                    }
                }
                Divider()
                InspectorView(task: task, store: store, changes: changes)
                    .frame(width: 280)
            }
            .task(id: task.status) {
                await loadChanges(task)
                // A running task keeps changing the tree; re-ask git while it runs.
                while task.status.isRunning, !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    if Task.isCancelled { break }
                    await loadChanges(task)
                }
            }
            .onChange(of: session?.id) { _, id in if id != nil { tab = .terminal } }
            .confirmationDialog(takeoverTitle(task), isPresented: Binding(get: { confirmTakeover != nil }, set: { if !$0 { confirmTakeover = nil } }), titleVisibility: .visible) {
                Button(task.status.isRunning ? "Stop it and take over" : "Continue in terminal") {
                    if let destination = confirmTakeover { model.takeover(taskID, to: destination) }
                    confirmTakeover = nil
                }
                Button("Cancel", role: .cancel) { confirmTakeover = nil }
            } message: {
                Text(takeoverMessage(task))
            }
            .confirmationDialog("Cancel this task?", isPresented: $confirmCancel, titleVisibility: .visible) {
                Button("Cancel task and its sub-tasks", role: .destructive) { model.cancel(taskID) }
            } message: {
                Text("polybridge stops the run and, best-effort, every live sub-task it started.")
            }
        } else {
            VStack(spacing: 8) {
                Text("Task \(taskID)").font(.headline)
                Text(model.hasListed ? "This task is not in polybridge's records (it may have been removed by retention)." : "Loading…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The baseline (`base_commit`, `start_dirty`) is only in the snapshot, never in a listing, so
    /// git is not asked until the snapshot is in hand — otherwise a missing field would read as
    /// "no baseline was recorded".
    private func loadChanges(_ task: TaskInfo) async {
        guard !task.repoPath.isEmpty else { return }
        if model.snapshots[taskID] == nil { await model.refreshSnapshot(taskID) }
        guard let snapshot = model.snapshots[taskID] else {
            changesError = "The task's baseline could not be read (polybridge-ctl status failed), so its changes are not shown."
            return
        }
        changesError = nil
        let inspector = GitInspector(environment: model.environment())
        changes = await inspector.changes(repo: task.repoPath, baseCommit: snapshot.baseCommit, startDirty: snapshot.startDirty)
    }

    private func takeoverTitle(_ task: TaskInfo) -> String {
        task.status.isRunning ? "Take over this task?" : "Continue this session in a terminal?"
    }

    private func takeoverMessage(_ task: TaskInfo) -> String {
        var text = task.status.isRunning
            ? "The headless run is stopped first (with any sub-tasks), then the same conversation opens in a terminal. "
            : "The same conversation opens in a terminal. "
        text += "It runs under your own default permissions, not this task's \(task.freedom ?? "freedom") level. While the terminal is open, polybridge refuses resumes of this session from anywhere else."
        return text
    }

    // MARK: Header

    @ViewBuilder
    private func header(_ task: TaskInfo, session: TerminalSession?) -> some View {
        let ancestors = Lineage.ancestors(of: taskID, in: model.tasks)
        let driving = session.map { !$0.ended } ?? false
        VStack(alignment: .leading, spacing: 6) {
            if !ancestors.isEmpty {
                HStack(spacing: 4) {
                    ForEach(ancestors) { ancestor in
                        Button(model.title(ancestor.taskID)) { model.selection = .task(ancestor.taskID) }
                            .buttonStyle(.link).lineLimit(1)
                        Text("›").foregroundStyle(.secondary)
                    }
                    Text(model.title(taskID)).foregroundStyle(.secondary).lineLimit(1)
                }
                .font(.system(size: 11))
            }
            HStack(alignment: .center, spacing: 10) {
                BackendBadge(backend: task.backend, size: 26)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.title(taskID)).font(.system(size: 16, weight: .semibold)).lineLimit(2).textSelection(.enabled)
                    HStack(spacing: 6) {
                        Text(task.backend).font(.system(size: 11, weight: .medium))
                        if let effort = task.reasoningEffort { Text("effort \(effort)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        FreedomBadge(freedom: task.freedom)
                        Text(Format.repo(task.repoPath)).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        if task.depth > 0 { Text("depth \(task.depth)").font(.system(size: 11)).foregroundStyle(.secondary) }
                        if let session = task.sessionID { Text("session \(session.prefix(8))").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary) }
                    }
                }
                Spacer()
                StatusPill(task: task, drivenByUser: driving)
                actions(task, driving: driving)
            }
            if let message = model.messages[taskID] {
                Text(message).font(.system(size: 11)).foregroundStyle(message.hasPrefix("Refused") ? Color.failedRed : .secondary).textSelection(.enabled)
            }
            if task.takenOver, !driving {
                Banner(icon: "person.fill", title: "Taken over", text: task.takenOverNote ?? "This session was handed to a person in the Monitor.")
            }
            if driving {
                Banner(icon: "terminal", title: "You're driving", text: "The headless run is stopped. Same conversation, full context, in the Terminal tab. Other callers see this session as taken over until you end the session.", tint: Color(hex: 0x8A4B00))
            }
            if !task.isRoot, let parentID = task.spawnedBy {
                Banner(icon: "arrow.turn.down.right", title: "Sub-task started by another agent",
                       text: "The \(model.task(parentID)?.backend ?? "parent") task “\(model.title(parentID))” called polybridge to start this. Its result goes back to that task when this finishes.")
            }
        }
        .padding(14)
    }

    @ViewBuilder
    private func actions(_ task: TaskInfo, driving: Bool) -> some View {
        let busy = model.busy.contains(taskID)
        HStack(spacing: 6) {
            if busy { ProgressView().controlSize(.small) }
            if !driving {
                Menu {
                    Button("In this window") { confirmTakeover = .embedded }
                    Button("In Terminal.app") { confirmTakeover = .terminalApp }
                } label: {
                    Text(task.status.isRunning ? "Take over" : "Continue in terminal")
                } primaryAction: {
                    confirmTakeover = .embedded
                }
                .fixedSize()
                .disabled(busy || task.sessionID == nil)
                .help(task.sessionID == nil ? "The task has not reported a session yet." : "Stop the headless run and resume the session interactively.")
            }
            if let parent = task.spawnedBy, model.task(parent) != nil {
                Button("Open parent") { model.selection = .task(parent) }
            }
            if task.status.isRunning {
                Button("Cancel", role: .destructive) { confirmCancel = true }.disabled(busy)
            }
        }
    }

    // MARK: Tabs

    private func tabs(session: TerminalSession?) -> [TaskTab] {
        var tabs: [TaskTab] = [.timeline, .changes, .prompt, .raw]
        if session != nil { tabs.insert(.terminal, at: 2) }
        return tabs
    }

    @ViewBuilder
    private func tabBar(_ task: TaskInfo, session: TerminalSession?) -> some View {
        HStack(spacing: 2) {
            ForEach(tabs(session: session)) { item in
                Button {
                    tab = item
                } label: {
                    HStack(spacing: 4) {
                        Text(item.rawValue)
                        if item == .changes, let count = changes?.files.count, count > 0 {
                            Text("\(count)").font(.system(size: 10, weight: .semibold)).padding(.horizontal, 5).background(Capsule().fill(Color.hairline))
                        }
                    }
                    .font(.system(size: 12, weight: tab == item ? .semibold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(tab == item ? Color.selectedRow : .clear))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
    }

    @ViewBuilder
    private func content(_ task: TaskInfo, session: TerminalSession?) -> some View {
        switch tab {
        case .timeline:
            TimelinePane(task: task, store: store)
        case .changes:
            ChangesPane(task: task, changes: changes, error: changesError, commands: Timeline.commands(in: store.items), reload: { Task { await loadChanges(task) } })
        case .prompt:
            ScrollView {
                Text(store.prompt ?? "The prompt is recorded in the task's event log, which has not been read yet (or does not exist).")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        case .raw:
            RawEventsPane(store: store)
        case .terminal:
            if let session { TerminalPane(session: session) } else { Text("No terminal").frame(maxWidth: .infinity, maxHeight: .infinity) }
        }
    }
}

struct RawEventsPane: View {
    @ObservedObject var store: EventStore

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(store.events) { event in
                    Text(event.rawLine).font(.system(size: 10, design: .monospaced)).foregroundStyle(event.isUnknown ? .secondary : .primary)
                        .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(10)
        }
        .overlay(alignment: .topTrailing) {
            Text(store.path).font(.system(size: 10)).foregroundStyle(.secondary).padding(6).textSelection(.enabled)
        }
    }
}

/// "Message this task" while a live-input run is going; "Continue" (a resume) once it settled.
struct MessageBox: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    @State private var text = ""

    private var canSend: Bool { task.liveInput && task.status.isRunning && !task.takenOver }
    private var canContinue: Bool { task.status.isTerminal && task.sessionID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(canSend ? "Message this task" : (canContinue ? "Continue this session" : "Messages")).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(hint).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!(canSend || canContinue))
                    .onSubmit(submit)
                Button(canSend ? "Send" : "Continue", action: submit)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!(canSend || canContinue) || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy.contains(task.taskID))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var placeholder: String {
        if canSend { return "Message this task while it runs…" }
        if canContinue { return "Send a follow-up — it resumes the session as a new task" }
        if task.status.isRunning { return "This task was not started with live input, so it cannot take messages while it runs." }
        return "This task has no session to continue."
    }

    private var hint: String {
        if canSend { return "Queued; folded into the current turn or sent after it" }
        if canContinue { return "Runs `resume` through polybridge" }
        return ""
    }

    private func submit() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        if canSend {
            model.send(task.taskID, text: message)
        } else if canContinue {
            model.resume(task.taskID, text: message)
        } else {
            return
        }
        text = ""
    }
}
