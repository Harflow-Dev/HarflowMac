import MonitorCore
import SwiftUI

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
            if model.runningCount > 0 { Text("\(model.runningCount)") }
        }
        .onAppear {
            // The status item is always alive, so it is where the window opener is captured for
            // URL handling and "Open Monitor".
            model.openWindowAction = { openWindow(id: "main") }
        }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        let sections = Lineage.sections(model.tasks)
        // Every running task, not just roots: a root can finish before the sub-task it started.
        let running = model.tasks.filter { $0.status.isRunning }.sorted { ($0.isRoot ? 0 : 1) < ($1.isRoot ? 0 : 1) }
        VStack(alignment: .leading, spacing: 0) {
            Text("Polybridge — \(model.runningCount) running").font(.system(size: 13, weight: .semibold)).padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let error = model.listError {
                        Text(error.message).font(.system(size: 11)).foregroundStyle(Color.failedRed)
                    }
                    ForEach(running) { task in
                        EventScope(taskID: task.taskID) { store in
                            MenuRunningRow(task: task, store: store)
                        }
                    }
                    if running.isEmpty, model.listError == nil {
                        Text("Nothing running.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    let recentGroups = sections.parallel.prefix(3)
                    let recent = sections.recent.prefix(6)
                    if !recentGroups.isEmpty || !recent.isEmpty {
                        SectionLabel(text: "Recent").padding(.top, 6)
                        ForEach(Array(recentGroups)) { group in
                            Button { open(.group(group.name)) } label: {
                                HStack { GroupRow(group: group) }.contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        ForEach(Array(recent)) { node in
                            Button { open(.task(node.id)) } label: {
                                HStack(spacing: 8) {
                                    BackendBadge(backend: node.task.backend, size: 18)
                                    Text(model.title(node.id)).font(.system(size: 12)).lineLimit(1)
                                    Spacer()
                                    Text(node.task.status.label).font(.system(size: 10)).foregroundStyle(StatusColor.of(node.task.status))
                                    Text(Format.age(node.task.startedAt)).font(.system(size: 10)).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(12)
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Button("Open Monitor") { model.showWindow() }.keyboardShortcut("o")
                Toggle("Open window when a task starts", isOn: $model.openWindowOnStart)
                Toggle("Notify when a task finishes", isOn: $model.notifyOnFinish)
            }
            .font(.system(size: 12))
            .padding(12)
            Divider()
            HStack {
                Circle().fill(model.listError == nil && model.hasListed ? Color.doneGreen : Color.failedRed).frame(width: 7, height: 7)
                Text(model.connectionLine).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }.buttonStyle(.borderless).font(.system(size: 11))
            }
            .padding(12)
        }
        .frame(width: 380, height: 580)
    }

    private func open(_ selection: Selection) {
        model.selection = selection
        model.showWindow()
    }
}

struct MenuRunningRow: View {
    @EnvironmentObject var model: AppModel
    let task: TaskInfo
    @ObservedObject var store: EventStore

    var body: some View {
        Button {
            model.selection = .task(task.taskID)
            model.showWindow()
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    BackendBadge(backend: task.backend, size: 18)
                    Text(model.title(task.taskID)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Format.clock(task.elapsed(now: context.date))).font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                if let current = store.current, case .tool(let call, _) = current.body {
                    Text("\(call.tool) \(call.headline)").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if let last = store.items.last, case .text(let text) = last.body {
                    Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                ProgressView().progressViewStyle(.linear).controlSize(.mini)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
