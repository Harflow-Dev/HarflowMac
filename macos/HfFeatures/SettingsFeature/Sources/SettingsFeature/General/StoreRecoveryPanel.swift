import HfUI
import SwiftUI

// MARK: - StoreRecoveryPanel

/// The Task store row. Inline exact-operation confirmation is cancelled when the Settings view disappears.
struct StoreRecoveryPanel: View {
    let model: StoreRecoveryPresentation
    let inspect: () -> Void
    let request: () -> Void
    let cancel: () -> Void
    let confirm: () -> Void
    let reveal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                if let glyph = model.glyph { RowGlyphView(glyph: glyph) }
                Text(model.title).font(.headline)
                Spacer(minLength: 12)
                controls
            }
            if let message = model.message { Text(message).foregroundStyle(.secondary).textSelection(.enabled) }
            ForEach(model.rows, id: \.label) { detail($0.label, $0.value) }
            if model.showsArchivalWarning {
                Text("Previous task history will be archived, not imported. "
                     + "Recovery checks cooperative ownership; close sessions using this store first. "
                     + "The backup is archival history, not an automatic restore.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if model.showsInterruptedNote {
                Text(StoreRecoveryPresentation.interruptedNote)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .opacity(model.inspectEnabled ? 1 : 0.55)
        .accessibilityElement(children: .contain)
    }

    private var controls: some View {
        HStack {
            if model.canInspect {
                Button("Inspect task store", action: inspect)
                    .disabled(!model.inspectEnabled)
                    .accessibilityIdentifier("state-recovery-inspect")
            }
            if let title = model.requestTitle {
                Button(title, action: request).accessibilityIdentifier("state-recovery-request")
            }
            if model.confirming {
                Button("Cancel", action: cancel).accessibilityIdentifier("state-recovery-cancel")
                Button(model.confirmationTitle, role: .destructive, action: confirm)
                    .accessibilityIdentifier("state-recovery-confirm")
            }
            if model.offersReveal {
                Button("Show backup in Finder", action: reveal).accessibilityIdentifier("state-recovery-reveal")
            }
        }
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
