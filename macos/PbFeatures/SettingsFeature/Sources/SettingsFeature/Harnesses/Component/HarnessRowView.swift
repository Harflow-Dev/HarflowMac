//
//  HarnessRowView.swift
//  SettingsFeature
//
//  A dumb component: takes the domain `HarnessRow` (MonitorCore) directly, plus the two per-row
//  flags a list needs (`isWorking`, `isAnyWorking`) and its two action closures. Ported verbatim
//  from the app target's `SettingsView.swift` (`HarnessSettings`'s row body).
//

import MonitorCore
import PbUI
import SwiftUI

// MARK: - HarnessRowActions

/// The row's own enable/disable rules, pulled out as pure functions so they are unit-testable
/// without a SwiftUI rendering harness (F4-45: Install is disabled unless available; Remove is
/// disabled only when `installed == false` — `nil`, "unknown", leaves it enabled).
enum HarnessRowActions {
    static func isInstallDisabled(row: HarnessRow, isAnyWorking: Bool) -> Bool {
        isAnyWorking || !row.available
    }
    
    static func isRemoveDisabled(row: HarnessRow, isAnyWorking: Bool) -> Bool {
        isAnyWorking || row.installed == false
    }

    /// Registered, but not what install would write now — most often a stale `PATH`, frozen when it
    /// was registered, that no longer reaches an agent CLI (installed later, or moved by an nvm Node
    /// upgrade). The registration then *looks* fine while dispatch fails, so it must not read as done.
    static func isOutOfDate(row: HarnessRow) -> Bool {
        row.installed == true && row.current == false
    }

    static func installTitle(row: HarnessRow) -> String {
        if isOutOfDate(row: row) { return "Update" }
        return row.installed == true ? "Reinstall" : "Install"
    }
}

// MARK: - HarnessRowView

struct HarnessRowView: View {
    let row: HarnessRow
    let isWorking: Bool
    let isAnyWorking: Bool
    let onInstall: () -> Void
    let onRemove: () -> Void
    var onAllowlist: () -> Void = {}
    
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(row.displayName).font(.pb(.headline, weight: .medium))
                    Text(row.stateLabel).font(.pb(.secondary)).foregroundStyle(stateColor)
                    if let action = row.action { Chip(text: "last: \(action)") }
                }
                if let rowError = row.error { Text(rowError).font(.pb(.secondary)).foregroundStyle(Color.failedRed) }
                ForEach(Array(row.notes.enumerated()), id: \.offset) { _, note in
                    Text(note).font(.pb(.secondary)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if isWorking { ProgressView().controlSize(.small) }
            Button("MCP approvals", action: onAllowlist).disabled(isAnyWorking)
            Button(HarnessRowActions.installTitle(row: row), action: onInstall)
                .disabled(HarnessRowActions.isInstallDisabled(row: row, isAnyWorking: isAnyWorking))
            Button("Remove", action: onRemove)
                .disabled(HarnessRowActions.isRemoveDisabled(row: row, isAnyWorking: isAnyWorking))
        }
        .padding(.vertical, 4)
    }

    private var stateColor: Color {
        if HarnessRowActions.isOutOfDate(row: row) { return .warningFG }
        return row.installed == true ? .doneGreen : .secondary
    }
}

#if DEBUG
#Preview {
    // `HarnessRow` has no public initializer (MonitorCore builds it internally from JSON), so the
    // preview goes through the same public `SetupDocument.decode` entry point the app uses — the
    // same pattern `PbRepositoryTests` already established for this type.
    let json = #"{"v":1,"server_path":"/usr/local/bin/polybridge","clients":[{"key":"claude-code","available":true,"installed":true,"current":true,"#
    + #""notes":["Registered via `claude mcp add`."]}]}"#
    if let document = try? SetupDocument.decode(stdout: Data(json.utf8), stderr: "", exitCode: 0).get() {
        List {
            HarnessRowView(row: document.rows[0], isWorking: false, isAnyWorking: false, onInstall: {}, onRemove: {})
        }
        .frame(width: 500, height: 120)
    }
}
#endif
