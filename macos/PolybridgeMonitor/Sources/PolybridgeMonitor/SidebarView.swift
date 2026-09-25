import MonitorCore
import SwiftUI

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var backendFilter = "all"

    private var sections: SidebarSections {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return Lineage.sections(model.tasks) { task in
            (backendFilter == "all" || task.backend == backendFilter)
                && (query.isEmpty
                    || model.title(task.taskID).lowercased().contains(query)
                    || task.taskID.lowercased().contains(query)
                    || task.repoPath.lowercased().contains(query))
        }
    }

    var body: some View {
        let sections = self.sections
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Button {
                    model.showNewSession = true
                } label: {
                    Label("New session", systemImage: "plus").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                TextField("Search tasks", text: $search)
                    .textFieldStyle(.roundedBorder)
                Picker("Backend", selection: $backendFilter) {
                    Text("All").tag("all")
                    ForEach(backendsInList, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(10)

            List(selection: $model.selection) {
                if let error = model.listError {
                    Section {
                        Text(error.message).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled)
                    }
                }
                if !sections.running.isEmpty {
                    Section { trees(sections.running) } header: { SectionLabel(text: "Running \(sections.running.count)") }
                }
                if !sections.parallel.isEmpty {
                    Section {
                        ForEach(sections.parallel) { group in
                            GroupRow(group: group).tag(Selection.group(group.name))
                        }
                    } header: { SectionLabel(text: "Parallel runs \(sections.parallel.count)") }
                }
                if !model.interactiveSessions.isEmpty {
                    Section {
                        ForEach(model.interactiveSessions) { session in
                            HStack {
                                BackendBadge(backend: session.backend, size: 18)
                                Text(session.title).lineLimit(1)
                                Spacer()
                                Circle().fill(Color.doneGreen).frame(width: 6, height: 6)
                            }
                            .tag(Selection.interactive(session.id))
                        }
                    } header: { SectionLabel(text: "Interactive") }
                }
                if !sections.recent.isEmpty {
                    Section { trees(sections.recent) } header: { SectionLabel(text: "Recent") }
                }
                if model.hasListed, model.tasks.isEmpty, model.listError == nil {
                    Text("No tasks yet. Tasks started through polybridge appear here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .listStyle(.sidebar)

            Divider()
            HStack {
                Circle().fill(model.listError == nil && model.hasListed ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(model.connectionLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.borderless)
            }
            .padding(10)
        }
    }

    private var backendsInList: [String] {
        Array(Set(model.tasks.map(\.backend))).sorted()
    }

    @ViewBuilder
    private func trees(_ roots: [TaskNode]) -> some View {
        ForEach(roots) { root in
            ForEach(root.flattened(), id: \.node.id) { entry in
                TaskRow(node: entry.node, indent: entry.indent).tag(Selection.task(entry.node.id))
            }
        }
    }
}

struct TaskRow: View {
    @EnvironmentObject var model: AppModel
    let node: TaskNode
    let indent: Int

    var body: some View {
        let task = node.task
        HStack(spacing: 8) {
            BackendBadge(backend: task.backend, size: indent == 0 ? 20 : 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(task.taskID)).font(.system(size: 12, weight: indent == 0 ? .medium : .regular)).lineLimit(1)
                Text(meta(task)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if model.session(forTask: task.taskID).map({ !$0.ended }) == true {
                Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Color(hex: 0x8A4B00))
            }
            if task.status.isRunning {
                Circle().fill(Color.runningFG).frame(width: 6, height: 6)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(Format.clock(task.elapsed(now: context.date))).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(task.status.label).font(.system(size: 10, weight: .medium)).foregroundStyle(StatusColor.of(task.status))
                    Text(Format.age(task.startedAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, CGFloat(indent) * 16)
    }

    private func meta(_ task: TaskInfo) -> String {
        var parts = [Format.repo(task.repoPath)]
        if node.descendantCount > 0 { parts.append("\(node.descendantCount) sub-task\(node.descendantCount == 1 ? "" : "s")") }
        if let freedom = task.freedom { parts.append(freedom) }
        return parts.joined(separator: " · ")
    }
}

struct GroupRow: View {
    let group: ParallelGroup

    var body: some View {
        HStack(spacing: 6) {
            HStack(spacing: -4) {
                ForEach(group.members.prefix(3)) { BackendBadge(backend: $0.task.backend, size: 16) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text("\(group.doneCount) of \(group.total) done").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if group.anyRunning { Circle().fill(Color.runningFG).frame(width: 6, height: 6) }
        }
    }
}
