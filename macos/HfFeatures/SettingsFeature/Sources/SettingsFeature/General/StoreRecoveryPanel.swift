import SwiftUI

// MARK: - StoreRecoveryPanel

/// Inline exact-operation confirmation is cancelled when the Settings view disappears.
struct StoreRecoveryPanel: View {
    let model: StoreRecoveryPresentation
    let inspect: () -> Void
    let request: () -> Void
    let cancel: () -> Void
    let confirm: () -> Void
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.title).font(.headline)
            Text(model.message).foregroundStyle(.secondary).textSelection(.enabled)
            if let root = model.root { detail("State root", root) }
            if let reason = model.reason { detail("Reason", reason) }
            if let backupPath = model.backupPath { detail("Backup path", backupPath) }
            if let operation = model.operationID { detail("Recovery operation", operation) }
            if let completed = model.completedBackupPath, completed != model.backupPath { detail("Previous recovery backup", completed) }
            if let phase = model.phase { detail("Phase", phase) }
            if model.requestTitle != nil || model.confirming {
                Text("Previous task history will be archived, not imported. "
                     + "Recovery checks cooperative ownership; close sessions using this store first. "
                     + "The backup is archival history, not an automatic restore.")
                    .font(.callout)
.foregroundStyle(.secondary)
            }
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel(model.title) }
            HStack {
                if model.canInspect {
                    Button("Inspect task store", action: inspect).accessibilityIdentifier("state-recovery-inspect")
                }
                if let title = model.requestTitle {
                    Button(title, action: request).accessibilityIdentifier("state-recovery-request")
                }
                if model.confirming {
                    Button("Cancel", action: cancel).accessibilityIdentifier("state-recovery-cancel")
                    Button(model.confirmationTitle, role: .destructive, action: confirm)
                        .accessibilityIdentifier("state-recovery-confirm")
                }
                if model.canReveal {
                    Button("Show backup in Finder", action: reveal).accessibilityIdentifier("state-recovery-reveal")
                }
            }
            if model.phase != nil, !model.canReveal, model.requestTitle == nil, !model.confirming, !model.busy {
                Text("Inspect again before retrying. Any reported backup evidence is retained; the operation may have partially completed.")
                    .font(.callout)
.foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospaced()).textSelection(.enabled)
        }
    }
}

#if DEBUG
#Preview("Task store inspection") {
    StoreRecoveryPanel(model: StoreRecoveryPresentation(state: .idle), inspect: {}, request: {}, cancel: {}, confirm: {}, reveal: {})
        .padding()
.frame(width: 560)
}
#endif
