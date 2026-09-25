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
}

// MARK: - HarnessRowView

struct HarnessRowView: View {
    let row: HarnessRow
    let isWorking: Bool
    let isAnyWorking: Bool
    let onInstall: () -> Void
    let onRemove: () -> Void
    
    var body: some View {
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
            if isWorking { ProgressView().controlSize(.small) }
            Button(row.installed == true ? "Reinstall" : "Install", action: onInstall)
                .disabled(HarnessRowActions.isInstallDisabled(row: row, isAnyWorking: isAnyWorking))
            Button("Remove", action: onRemove)
                .disabled(HarnessRowActions.isRemoveDisabled(row: row, isAnyWorking: isAnyWorking))
        }
        .padding(.vertical, 4)
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
