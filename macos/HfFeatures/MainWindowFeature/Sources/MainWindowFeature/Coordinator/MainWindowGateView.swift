import SwiftUI

// MARK: - MainWindowGateView

/// The main pane of a contract-refused or capability-missing gate. Copy follows HarflowDesign e1c9230
/// (`app-states/contract-refused`, `app-states/capability-missing`).
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
            actionTitle: "Retry",
            action: retry
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("main-window-gate")
    }

    struct Copy: Equatable {
        let title: String
        let body: String
        let status: String
        let rows: [RuntimeGateDetailRow]
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
        }
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
