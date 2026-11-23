import HfRepository
import MonitorCore
import SwiftUI

// MARK: - MainWindowGateView

/// The main pane of a contract-refused, capability-missing or store-unusable gate. Copy follows HarflowDesign e1c9230
/// (`app-states/contract-refused`, `app-states/capability-missing`, `app-states/store-unusable`).
struct MainWindowGateView: View {
    let gate: MainWindowGate
    let retry: () -> Void

    var body: some View {
        let copy = Self.copy(for: gate)
        return RuntimeGateView(
            title: copy.title,
            bodyText: copy.body,
            statusText: copy.status,
            statusIsSecondary: true,
            detailRows: copy.rows,
            actionTitle: copy.actionTitle,
            actionOpensSettings: copy.opensSettings,
            action: retry
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main-window-gate")
    }

    struct Copy: Equatable {
        let title: String
        let body: String
        let status: String?
        let rows: [RuntimeGateDetailRow]
        var actionTitle = "Retry"
        /// The action opens the Settings window instead of retrying the listing.
        var opensSettings = false
    }

    private nonisolated static func codeRows(_ code: String?) -> [RuntimeGateDetailRow] {
        code.map { [RuntimeGateDetailRow(label: "Code", value: $0)] } ?? []
    }

    nonisolated static func copy(for gate: MainWindowGate) -> Copy {
        switch gate {
        case .contractRefused(let status, let code):
            Copy(title: "This Harflow runtime doesn't match the app",
                 body: "Update the Harflow app to a version that matches this runtime.",
                 status: status, rows: codeRows(code))
        case .capabilityMissing(let status, let code):
            Copy(title: "This Harflow runtime is missing a feature the app needs",
                 body: "Update the Harflow app to get a runtime that has it.",
                 status: status, rows: codeRows(code))
        case .storeUnusable(let attention):
            // The drawing has no status line: the engine's sentence is the body, the detail rows follow it. The Reason row
            // and the Code row are exclusive, because a refusal shows its code only when no engine reason explains it.
            Copy(title: attention.title, body: attention.message, status: nil,
                 rows: storeRows(attention), actionTitle: "Open Settings", opensSettings: true)
        }
    }

    private nonisolated static func storeRows(_ attention: StoreAttention) -> [RuntimeGateDetailRow] {
        var rows: [RuntimeGateDetailRow] = []
        if let root = attention.stateRoot { rows.append(RuntimeGateDetailRow(label: "State root", value: root)) }
        if let reason = attention.reason { rows.append(RuntimeGateDetailRow(label: "Reason", value: reason)) }
        if let code = attention.code { rows.append(RuntimeGateDetailRow(label: "Code", value: code)) }
        return rows
    }
}

#if DEBUG
#Preview("Contract refused, light") {
    MainWindowGateView(
        gate: .contractRefused(status: "harflow-ctl answered with contract version 2; this app understands version 1. "
            + "Update the app or harflow so they match.", code: nil),
        retry: {}
    )
    .frame(width: 800, height: 600)
    .preferredColorScheme(.light)
}

#Preview("Store unusable, light") {
    MainWindowGateView(
        gate: .storeUnusable(StoreAttention(error: .structuredRefusal(
            code: "state_incompatible",
            message: "Unsupported state root: foreign store marker; inspect state or select a fresh state root",
            data: ["reason": .string("foreign_store"),
                   "state_root": .string("/Users/me/Library/Application Support/Harflow/State")]
        ))),
        retry: {}
    )
    .frame(width: 800, height: 600)
    .preferredColorScheme(.light)
}

#Preview("Capability missing, dark") {
    MainWindowGateView(
        gate: .capabilityMissing(status: "Incompatible Harflow runtime: missing required events.v1 contract/capability",
                                 code: "incompatible_runtime"),
        retry: {}
    )
    .frame(width: 800, height: 600)
    .preferredColorScheme(.dark)
}
#endif
