import MonitorCore
import SwiftUI

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            SidebarView().navigationSplitViewColumnWidth(min: 240, ideal: 260, max: 340)
        } detail: {
            switch model.selection {
            case .task(let id): TaskDetailView(taskID: id)
            case .group(let name): ParallelView(name: name)
            case .interactive(let id):
                if let session = model.sessions.first(where: { $0.id == id }) {
                    InteractiveView(session: session)
                } else {
                    Text("This terminal has closed.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case nil:
                VStack(spacing: 8) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("Select a task").font(.headline)
                    Text("Tasks started through polybridge show up in the sidebar, live.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .sheet(isPresented: $model.showNewSession) { NewSessionSheet() }
        .frame(minWidth: 1000, minHeight: 620)
    }
}

struct InteractiveView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                BackendBadge(backend: session.backend, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.title).font(.system(size: 16, weight: .semibold))
                    Text("Interactive session started from the Monitor · not a polybridge task, so it is not tracked or reserved")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(14)
            Divider()
            TerminalPane(session: session)
        }
    }
}

struct NewSessionSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var backend = "claude"
    @State private var repo = ""
    @State private var interactive = true
    @State private var freedom = "read_only"
    @State private var message = ""
    @State private var error: String?
    @State private var starting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New session").font(.system(size: 17, weight: .semibold))
                Text("Start an agent from the app. A headless task shows up in the sidebar like any other task.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Agent")
                Picker("Agent", selection: $backend) {
                    ForEach(BackendStyle.known, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .pickerStyle(.segmented).labelsHidden()
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: "Repository")
                HStack {
                    TextField("/path/to/repo", text: $repo).textFieldStyle(.roundedBorder)
                    Button("Choose…", action: choose)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "How to run it")
                Picker("Mode", selection: $interactive) {
                    VStack(alignment: .leading) {
                        Text("Interactive terminal")
                        Text("Opens a terminal here running \(backend) in the repo. You type; it asks before editing, like running it yourself.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.tag(true)
                    VStack(alignment: .leading) {
                        Text("Headless task")
                        Text("Runs through polybridge with a freedom level, shown on the timeline. You can message it (claude) or take over later.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }.tag(false)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if !interactive {
                    Picker("Freedom", selection: $freedom) {
                        ForEach(["read_only", "write_in_repo", "publish", "unrestricted"], id: \.self) { Text($0).tag($0) }
                    }
                    .frame(width: 280)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: interactive ? "First message (type it in the terminal)" : "First message")
                TextEditor(text: $message)
                    .font(.system(size: 12))
                    .frame(height: 110)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.hairline))
                    .disabled(interactive)
                    .opacity(interactive ? 0.5 : 1)
            }
            if let error {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(starting ? "Starting…" : "Start session", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(starting || repo.isEmpty || (!interactive && message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
            }
        }
        .padding(20)
        .frame(width: 560, height: 600)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { repo = url.path }
    }

    private func start() {
        let path = (repo as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            error = "Choose an existing folder."
            return
        }
        error = nil
        if interactive {
            if let failure = model.startInteractive(backend: backend, repo: path) { error = failure } else { dismiss() }
            return
        }
        starting = true
        model.startHeadless(RunRequest(backend: backend, repo: path, prompt: message, freedom: freedom)) { failure in
            starting = false
            if let failure { error = failure } else { dismiss() }
        }
    }
}
