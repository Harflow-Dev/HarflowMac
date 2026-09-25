import MonitorCore
import SwiftUI

struct TimelinePane: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    @ObservedObject var store: EventStore
    @State private var followLive = true

    var body: some View {
        let items = store.items
        let children = Lineage.children(of: task.taskID, in: model.tasks)
        let start = task.startedAt ?? items.first?.at
        VStack(spacing: 0) {
            HStack {
                Text("\(items.count) steps").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Toggle("Follow live", isOn: $followLive).toggleStyle(.checkbox).font(.system(size: 11))
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if items.isEmpty {
                            Text(task.status.isRunning ? "Waiting for the first event…" : "This task's event log is empty or was not found.")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            TimelineRow(item: item, start: start, live: task.status.isRunning).id(item.id)
                        }
                        if !children.isEmpty {
                            SubTaskStrip(children: children, start: start)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(14)
                }
                .onChange(of: items.count) { _, _ in
                    if followLive { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
    }
}

struct SubTaskStrip: View {
    @EnvironmentObject var model: AppModel
    let children: [TaskInfo]
    let start: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Started \(children.count) sub-task\(children.count == 1 ? "" : "s") via polybridge").font(.system(size: 12, weight: .medium))
            ForEach(children) { child in
                Button {
                    model.selection = .task(child.taskID)
                } label: {
                    HStack(spacing: 8) {
                        BackendBadge(backend: child.backend, size: 18)
                        Text(model.title(child.taskID)).lineLimit(1)
                        FreedomBadge(freedom: child.freedom)
                        Spacer()
                        Text(child.status.label).foregroundStyle(StatusColor.of(child.status))
                        Text(Format.offset(child.startedAt, from: start)).monospacedDigit().foregroundStyle(.secondary)
                        Image(systemName: "chevron.right").foregroundStyle(.secondary)
                    }
                    .font(.system(size: 11))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct TimelineRow: View {
    let item: TimelineItem
    let start: Date?
    let live: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(Format.offset(item.at, from: start))
                .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 44, alignment: .trailing)
            rowBody
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var rowBody: some View {
        switch item.body {
        case .started(let started):
            VStack(alignment: .leading, spacing: 2) {
                Text("Started" + (started.spawnedBy != nil ? " by another task via polybridge" : " via polybridge")).font(.system(size: 12, weight: .medium))
                Text([started.backend, started.freedom, started.reasoningEffort.map { "effort \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .text(let text):
            MarkdownText(text: text)
        case .tool(let call, let result):
            ToolRow(call: call, result: result, live: live)
        case .message(let text, let source):
            VStack(alignment: .leading, spacing: 2) {
                Text(source == "injected" ? "Message sent to the task" : (source == "initial" ? "Prompt" : "User message"))
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentLink)
                Text(text).font(.system(size: 12)).lineLimit(source == "initial" ? 6 : nil).textSelection(.enabled)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.runningBG.opacity(0.6)))
        case .notice(let text):
            Label(text, systemImage: "info.circle").font(.system(size: 11)).foregroundStyle(.secondary)
        case .undelivered(let text, let reason):
            Label("Not delivered: \(text ?? "message")" + (reason.map { " — \($0)" } ?? ""), systemImage: "exclamationmark.triangle")
                .font(.system(size: 11)).foregroundStyle(Color.failedRed)
        case .finished(let status, let exitCode, _):
            let color = StatusColor.of(TaskStatus(status))
            Label("Finished: \(TaskStatus(status).label)" + (exitCode.map { " · exit \($0)" } ?? ""), systemImage: "flag.checkered")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(color)
        }
    }
}

struct ToolRow: View {
    let call: TaskEvent.ToolCall
    let result: TaskEvent.ToolResult?
    let live: Bool
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                expanded.toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: icon).frame(width: 14).foregroundStyle(.secondary)
                    Text(call.tool).font(.system(size: 12, weight: .medium))
                    Text(call.headline).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let result {
                        if let code = result.exitCode { Text("exit \(code)").font(.system(size: 10)).foregroundStyle(code == 0 ? Color.doneGreen : Color.failedRed) }
                        else if !result.ok { Text("failed").font(.system(size: 10)).foregroundStyle(Color.failedRed) }
                    } else if live {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .buttonStyle(.plain)
            if let old = call.editOld, let new = call.editNew {
                EditPreview(old: old, new: new)
            }
            if expanded || (result == nil && live && call.category == "shell") {
                if let output = result?.outputTail, !output.isEmpty {
                    Text(output).font(.system(size: 10, design: .monospaced)).lineLimit(expanded ? nil : 6)
                        .textSelection(.enabled).padding(6).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF5F5F7)))
                } else if expanded {
                    Text(call.inputPreview).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var icon: String {
        switch call.category {
        case "read": return "doc.text"
        case "search": return "magnifyingglass"
        case "edit", "write": return "pencil"
        case "shell": return "terminal"
        case "mcp": return "puzzlepiece"
        case "web": return "globe"
        default: return "wrench"
        }
    }
}

struct EditPreview: View {
    let old: String
    let new: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(old.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                Text("− " + line).foregroundStyle(Color.failedRed)
            }
            ForEach(Array(new.split(separator: "\n", omittingEmptySubsequences: false).prefix(8).enumerated()), id: \.offset) { _, line in
                Text("+ " + line).foregroundStyle(Color.doneGreen)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color(hex: 0xF8F8FA)))
    }
}

struct ChangesPane: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    let changes: GitChanges?
    let error: String?
    let commands: [(command: String, exitCode: Int?, ok: Bool?)]
    let reload: () -> Void
    @State private var selectedPath: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let changes {
                    HStack(alignment: .top) {
                        Banner(icon: changes.comparedWithBase ? "checkmark.seal" : "exclamationmark.triangle",
                               title: changes.comparedWithBase ? "Checked against git" : "Could not check against git",
                               text: ([changes.summaryLine] + changes.labels + changes.failures.dropFirst().map { "git \($0.query): \($0.detail)" }).joined(separator: "\n"),
                               tint: changes.comparedWithBase ? .accentLink : .failedRed)
                        Button("Refresh", action: reload)
                    }
                    if !changes.files.isEmpty {
                        SectionLabel(text: "Files")
                        VStack(spacing: 0) {
                            ForEach(changes.files) { file in
                                Button {
                                    selectedPath = file.path
                                } label: {
                                    HStack {
                                        Text(file.isUntracked ? "A" : file.status).font(.system(size: 11, weight: .bold, design: .monospaced))
                                            .foregroundStyle(file.status == "D" ? Color.failedRed : Color.doneGreen).frame(width: 16)
                                        Text(file.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                                        if file.isUntracked { Text("untracked").font(.system(size: 10)).foregroundStyle(.secondary) }
                                        Spacer()
                                        if let added = file.added, let removed = file.removed {
                                            Text("+\(added)").foregroundStyle(Color.doneGreen)
                                            Text("−\(removed)").foregroundStyle(Color.failedRed)
                                        }
                                    }
                                    .font(.system(size: 11, design: .monospaced))
                                    .padding(.vertical, 5).padding(.horizontal, 8)
                                    .background(selectedPath == file.path ? Color.selectedRow : .clear)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                    }
                } else if let error {
                    Banner(icon: "exclamationmark.triangle", title: "Changes unavailable", text: error, tint: .failedRed)
                } else {
                    ProgressView("Asking git…")
                }
                if task.status.isTerminal, let summary = model.snapshots[task.taskID]?.summary ?? task.summary, !summary.isEmpty {
                    SectionLabel(text: "Agent summary (the agent's own words)")
                    MarkdownText(text: summary)
                }
                if !commands.isEmpty {
                    SectionLabel(text: "Commands run")
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(commands.enumerated()), id: \.offset) { _, entry in
                            HStack(spacing: 8) {
                                Text(entry.exitCode.map { "exit \($0)" } ?? (entry.ok == false ? "failed" : (entry.ok == nil ? "running" : "ok")))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle((entry.exitCode ?? (entry.ok == false ? 1 : 0)) == 0 ? Color.doneGreen : Color.failedRed)
                                    .frame(width: 54, alignment: .leading)
                                Text(entry.command).font(.system(size: 11, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                            }
                        }
                    }
                }
                if let changes, let path = selectedPath ?? changes.diffs.first?.path {
                    if let diff = changes.diffs.first(where: { $0.path == path }) {
                        DiffView(diff: diff)
                    } else if changes.files.first(where: { $0.path == path })?.isUntracked == true {
                        UntrackedPreview(repo: task.repoPath, path: path)
                    }
                }
            }
            .padding(14)
        }
    }
}

struct DiffView: View {
    let diff: DiffFile

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(diff.oldPath.map { "\($0) → \(diff.path)" } ?? diff.path).font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("+\(diff.added) −\(diff.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            .padding(8)
            Divider()
            if diff.isBinary {
                Text("Binary file").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
            ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                Text(hunk.header).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .padding(.horizontal, 8).padding(.vertical, 3).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(hex: 0xF0F4FA))
                ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 0) {
                        Text(line.oldNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                        Text(line.newNumber.map(String.init) ?? "").frame(width: 38, alignment: .trailing).foregroundStyle(.secondary)
                        Text(prefix(line.kind) + line.text).padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .background(background(line.kind))
                }
            }
        }
        .textSelection(.enabled)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: return "+ "
        case .removed: return "− "
        case .context: return "  "
        case .noNewline: return ""
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: return Color(hex: 0xE6F4EA)
        case .removed: return Color(hex: 0xFCE8E6)
        default: return .clear
        }
    }
}

/// Untracked files have no diff; show the start of a small text file as all-new lines.
struct UntrackedPreview: View {
    let repo: String
    let path: String
    @State private var text: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(path) (untracked)").font(.system(size: 12, weight: .semibold))
            Text(text ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.doneGreen).textSelection(.enabled)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
        .task(id: path) {
            let url = URL(fileURLWithPath: repo).appendingPathComponent(path)
            guard let handle = try? FileHandle(forReadingFrom: url) else { text = "(unreadable)"; return }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 64 * 1024)) ?? Data()
            text = data.contains(0) ? "(binary)" : String(decoding: data, as: UTF8.self)
        }
    }
}
