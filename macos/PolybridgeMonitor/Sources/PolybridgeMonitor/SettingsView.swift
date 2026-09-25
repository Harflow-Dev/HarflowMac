import MonitorCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            HarnessSettings().tabItem { Label("Harnesses", systemImage: "puzzlepiece.extension") }
        }
        .frame(width: 620, height: 460)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var directory = ""

    var body: some View {
        Form {
            Section("polybridge tools") {
                TextField("Folder holding polybridge-ctl (blank = search)", text: $directory)
                    .onSubmit(apply)
                HStack {
                    Button("Apply", action: apply)
                    Button("Search again") { directory = ""; apply() }
                }
                Text("Searched: " + model.locator.searchDirectories.joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                resolved("polybridge-ctl")
                resolved("polybridge-setup")
                Text("Everything the app runs gets your login-shell PATH, no PB_* variables, and PB_OPEN_MONITOR=0.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Behaviour") {
                Toggle("Open the window when a task starts", isOn: $model.openWindowOnStart)
                Toggle("Notify when a task finishes", isOn: $model.notifyOnFinish)
            }
        }
        .formStyle(.grouped)
        .onAppear { directory = model.toolDirectory }
    }

    private func apply() {
        model.toolDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        model.settingsChanged()
    }

    @ViewBuilder
    private func resolved(_ tool: String) -> some View {
        switch model.locator.locate(tool) {
        case .success(let path): Label("\(tool): \(path)", systemImage: "checkmark.circle").font(.system(size: 11)).foregroundStyle(Color.doneGreen)
        case .failure: Label("\(tool): not found", systemImage: "xmark.circle").font(.system(size: 11)).foregroundStyle(Color.failedRed)
        }
    }
}

/// Rows from `polybridge-setup --status --json`. Install and Remove run `polybridge-setup` only
/// when clicked, after a confirmation: they change another app's configuration.
struct HarnessSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [HarnessRow] = []
    @State private var serverPath: String?
    @State private var error: String?
    @State private var loading = false
    @State private var working: String?
    @State private var pending: (action: SetupClient.Action, row: HarnessRow)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Where polybridge is registered as an MCP server").font(.system(size: 13, weight: .semibold))
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await load() } }.disabled(loading || working != nil)
            }
            if let serverPath { Text("Server: \(serverPath)").font(.system(size: 11)).foregroundStyle(.secondary) }
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Color.failedRed).textSelection(.enabled) }
            List(rows) { row in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(row.displayName).font(.system(size: 13, weight: .medium))
                            Text(row.stateLabel).font(.system(size: 11)).foregroundStyle(row.installed == true ? Color.doneGreen : .secondary)
                            if let action = row.action { Chip(text: "last: \(action)") }
                        }
                        if let rowError = row.error { Text(rowError).font(.system(size: 11)).foregroundStyle(Color.failedRed) }
                        ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                            Text(note).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    if working == row.key { ProgressView().controlSize(.small) }
                    Button(row.installed == true ? "Reinstall" : "Install") { pending = (.install, row) }
                        .disabled(working != nil || !row.available)
                    Button("Remove") { pending = (.remove, row) }
                        .disabled(working != nil || row.installed == false)
                }
                .padding(.vertical, 4)
            }
        }
        .padding(16)
        .task { await load() }
        .confirmationDialog(confirmTitle, isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
            Button(pending?.action == .remove ? "Remove" : "Install") {
                if let pending { Task { await run(pending.action, pending.row) } }
                pending = nil
            }
        } message: {
            Text("This runs polybridge-setup, which edits \(pending?.row.displayName ?? "the client")'s own configuration.")
        }
    }

    private var confirmTitle: String {
        guard let pending else { return "" }
        return pending.action == .remove ? "Remove polybridge from \(pending.row.displayName)?" : "Install polybridge into \(pending.row.displayName)?"
    }

    private func load() async {
        loading = true
        defer { loading = false }
        switch model.setup() {
        case .failure(let failure): error = failure.message
        case .success(let client):
            switch await client.perform(.status) {
            case .success(let document):
                rows = document.rows
                serverPath = document.serverPath
                error = nil
            case .failure(let failure): error = failure.message
            }
        }
    }

    private func run(_ action: SetupClient.Action, _ row: HarnessRow) async {
        guard case .success(let client) = model.setup() else { return }
        working = row.key
        defer { working = nil }
        switch await client.perform(action, client: row.key) {
        case .success(let document):
            // The action's own outcome for this row, then a fresh status for everything.
            if let updated = document.rows.first(where: { $0.key == row.key }), let index = rows.firstIndex(where: { $0.key == row.key }) {
                rows[index] = updated
            }
            error = nil
        case .failure(let failure):
            error = failure.message
        }
    }
}
