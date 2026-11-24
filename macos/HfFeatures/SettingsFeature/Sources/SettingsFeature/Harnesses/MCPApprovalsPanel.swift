import HfCommon
import HfRepository
import HfUI
import SwiftUI

// MARK: - MCPAllowlistViewModel

@MainActor
protocol MCPAllowlistViewModel: ViewModel {
    var title: String { get }
    var entry: String { get set }
    var entries: [String] { get }
    var configPath: String { get }
    var detail: String { get }
    var supported: Bool { get }
    var isBusy: Bool { get }
    var errorMessage: String? { get }
    /// The refusal code that goes on a "Code" line under `errorMessage`, when there is one.
    var errorCode: String? { get }
    /// The missing-feature sentence for a runtime without the approvals command.
    var missingFeatureSentence: String? { get }
    /// A read or change has answered and the harness's approvals are editable but empty.
    var showsEmpty: Bool { get }
    /// The entry field is enabled: a read has answered and the harness is supported.
    var fieldEnabled: Bool { get }
    /// Add and Remove are enabled: the field's condition and no request running.
    var actionsEnabled: Bool { get }
    var canAdd: Bool { get }
    var entryPlaceholder: String { get }
    var entryHelp: String { get }
    func load() async
    func confirmAdd()
    func confirmRemove(_ value: String)
}

// MARK: - MCPApprovalsPanel

/// The global MCP approvals of one harness, drawn inline under its row (the design's `#mcp-approvals`):
/// note, config path, engine detail, a refusal with its Code line or the missing-feature sentence, the empty
/// line or the entries with Remove, then the entry field with its hint, Add approval and Refresh.
struct MCPApprovalsPanel<VM: MCPAllowlistViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @State var viewModel: VM

    init(viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
            Text("Global tool approvals apply across projects and future tasks.")
                .font(.hf(.caption))
                .foregroundStyle(Color.secondaryText)
            if !viewModel.configPath.isEmpty {
                Text(viewModel.configPath)
                    .font(.hf(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
            }
            if !viewModel.detail.isEmpty {
                Text(viewModel.detail)
                    .font(.hf(.caption))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.failedRed)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let code = viewModel.errorCode { DetailLine(label: "Code", value: code) }
            }
            if let sentence = viewModel.missingFeatureSentence {
                Text(sentence)
                    .font(.hf(.secondary))
                    .foregroundStyle(Color.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if viewModel.showsEmpty {
                Text("No global approvals yet.").font(.hf(.secondary)).foregroundStyle(Color.secondaryText)
            }
            ForEach(viewModel.entries, id: \.self) { entry in
                HStack {
                    Text(entry).font(.hf(.secondary, design: .monospaced)).textSelection(.enabled)
                    Spacer()
                    Button("Remove") { viewModel.confirmRemove(entry) }
                        .disabled(!viewModel.actionsEnabled)
                        .accessibilityLabel("Remove approval \(entry)")
                }
            }
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing4) {
                    TextField(viewModel.entryPlaceholder, text: $viewModel.entry)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!viewModel.fieldEnabled)
                        .accessibilityLabel("Tool approval")
                    Text(viewModel.entryHelp).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                }
                Button("Add approval") { viewModel.confirmAdd() }.disabled(!viewModel.canAdd)
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh") { Task { await viewModel.load() } }.disabled(viewModel.isBusy)
            }
        }
        .padding(.vertical, HfRadius.Metrics.spacing8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await viewModel.load() }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable
@MainActor
private final class MCPApprovalsPreview: MCPAllowlistViewModel {
    let title = "Codex"
    var entry = ""
    var entries = ["harflow/*"]
    var configPath = "~/.codex/config.toml"
    var detail = "Global rules apply to future sessions. Harness deny rules and project overrides still apply."
    var supported = true
    var isBusy = false
    var errorMessage: String?
    var errorCode: String?
    var missingFeatureSentence: String?
    var showsEmpty = false
    var fieldEnabled = true
    var actionsEnabled = true
    let canAdd = false
    let entryPlaceholder = "server/tool or server/*"
    let entryHelp = "Use server/* to approve every tool on one server."
    func load() async {}
    func confirmAdd() {}
    func confirmRemove(_ value: String) {}

    static func refused() -> MCPApprovalsPreview {
        let preview = MCPApprovalsPreview()
        preview.errorMessage = "Harness configuration changed; reload and try again"
        preview.errorCode = "allowlist_error"
        preview.entry = "github/get_issue"
        return preview
    }

    static func missingFeature() -> MCPApprovalsPreview {
        let preview = MCPApprovalsPreview()
        preview.entries = []
        preview.configPath = ""
        preview.detail = ""
        preview.fieldEnabled = false
        preview.actionsEnabled = false
        preview.missingFeatureSentence = MissingFeature.sentence(canDo: "edit global MCP approvals")
        return preview
    }
}

#Preview("MCP approvals - light") {
    MCPApprovalsPanel(viewModel: MCPApprovalsPreview()).padding().preferredColorScheme(.light)
}

#Preview("MCP approvals - dark") {
    MCPApprovalsPanel(viewModel: MCPApprovalsPreview()).padding().preferredColorScheme(.dark)
}

#Preview("MCP approvals, change refused - light") {
    MCPApprovalsPanel(viewModel: MCPApprovalsPreview.refused()).padding().preferredColorScheme(.light)
}

#Preview("MCP approvals, runtime missing a feature - dark") {
    MCPApprovalsPanel(viewModel: MCPApprovalsPreview.missingFeature()).padding().preferredColorScheme(.dark)
}
#endif
