import PbCommon
import PbUI
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
    var canAdd: Bool { get }
    var entryPlaceholder: String { get }
    var entryHelp: String { get }
    func load() async
    func confirmAdd()
    func confirmRemove(_ value: String)
}

// MARK: - MCPAllowlistView

struct MCPAllowlistView<VM: MCPAllowlistViewModel>: View {
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.dismiss) private var dismiss
    @State var viewModel: VM

    init(viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing12) {
            HStack {
                Text("\(viewModel.title) MCP approvals").font(.pb(.headline))
                Spacer()
                if viewModel.isBusy { ProgressView().controlSize(.small) }
                Button("Done") { dismiss() }.disabled(viewModel.isBusy)
            }
            Text("Global tool approvals apply across projects and future tasks.")
                .font(.pb(.secondary))
.foregroundStyle(Color.secondaryText)
            if !viewModel.configPath.isEmpty {
                Text(viewModel.configPath)
                    .font(.pb(.caption, design: .monospaced))
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
            }
            if !viewModel.detail.isEmpty { Text(viewModel.detail).font(.pb(.secondary)).textSelection(.enabled) }
            if let error = viewModel.errorMessage { Text(error).foregroundStyle(Color.failedRed).textSelection(.enabled) }
            List {
                ForEach(viewModel.entries, id: \.self) { entry in
                    HStack {
                        Text(entry).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { viewModel.confirmRemove(entry) }.disabled(!viewModel.supported || viewModel.isBusy)
                    }
                }
            }
            // Bounded scope (§6.7): the approvals List's own scroll view, independent of row
            // presence — an empty or repopulated list keeps its chrome.
            .scrollChromeScope()
            .frame(minHeight: PbRadius.Metrics.mcpAllowlistMinimumHeight, maxHeight: PbRadius.Metrics.mcpAllowlistMaximumHeight)
            Text(viewModel.entryHelp).font(.pb(.caption)).foregroundStyle(Color.secondaryText)
            HStack {
                TextField(viewModel.entryPlaceholder, text: $viewModel.entry)
                    .textFieldStyle(.roundedBorder)
                    .disabled(!viewModel.supported || viewModel.isBusy)
                Button("Add approval") { viewModel.confirmAdd() }.disabled(!viewModel.canAdd)
                Button("Refresh") { Task { await viewModel.load() } }.disabled(viewModel.isBusy)
            }
        }
        .padding(PbRadius.Metrics.spacing20)
        .frame(width: PbRadius.Metrics.mcpAllowlistSheetWidth)
        .task { await viewModel.load() }
        .interactiveDismissDisabled(viewModel.isBusy)
        .publishViewEvent(from: viewModel, to: viewEvent)
    }
}

#if DEBUG
@Observable
@MainActor
private final class MCPAllowlistPreview: MCPAllowlistViewModel {
    let title = "Codex"
    var entry = ""
    let entries = ["polybridge/*"]
    let configPath = "~/.codex/config.toml"
    let detail = "Other harness policies still apply."
    let supported = true
    var isBusy = false
    let errorMessage: String? = nil
    let canAdd = false
    let entryPlaceholder = "server/tool or server/*"
    let entryHelp = "Use server/* to approve every tool on one server."
    func load() async {}
    func confirmAdd() {}
    func confirmRemove(_ value: String) {}
}

#Preview("MCP approvals - light") {
    MCPAllowlistView(viewModel: MCPAllowlistPreview()).preferredColorScheme(.light)
}

#Preview("MCP approvals - dark") {
    MCPAllowlistView(viewModel: MCPAllowlistPreview()).preferredColorScheme(.dark)
}
#endif
