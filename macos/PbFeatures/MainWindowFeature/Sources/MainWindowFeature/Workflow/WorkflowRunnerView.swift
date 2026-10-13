import MonitorCore
import PbCommon
import PbUI
import SwiftUI

// MARK: - WorkflowRunnerView

/// Chooses a saved definition before entering the existing permission-preview launch flow.
struct WorkflowRunnerView<VM: WorkflowViewModel>: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.viewEvent) private var viewEvent
    @State private var viewModel: VM
    @State private var selectedName = ""
    @State private var pendingLaunchName: String?

    init(_ viewModel: VM) { _viewModel = State(initialValue: viewModel) }

    var body: some View {
        Group {
            if viewModel.showsRunSheet {
                WorkflowLaunchSheet(viewModel: viewModel, isGenerating: false)
            } else {
                chooser
            }
        }
        .onAppear { viewModel.didAppear() }
        .onDisappear { viewModel.didDisappear() }
        .onChange(of: viewModel.initialLoadingKind) { _, _ in finishLoading() }
        .onChange(of: viewModel.showsRunSheet) { wasPresented, isPresented in
            if wasPresented, !isPresented { dismiss() }
        }
        .publishViewEvent(from: viewModel, to: viewEvent)
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: PbRadius.Metrics.spacing16) {
            Text("Run Workflow").font(.pb(.headline, weight: .semibold))
            Text("Choose a saved workflow, then review its permissions and task before running.")
                .foregroundStyle(Color.secondaryText)
            Picker("Workflow", selection: $selectedName) {
                Text("Choose a workflow").tag("")
                ForEach(viewModel.workflows) { workflow in
                    Text(workflow.id).tag(workflow.id)
                }
            }
            .disabled(viewModel.initialLoadingKind != nil)
            if viewModel.workflows.isEmpty {
                Text("No saved workflows are available. Create and save a workflow first.")
                    .foregroundStyle(Color.secondaryText)
            }
            if viewModel.initialLoadingKind != nil { ProgressView("Loading workflow…") }
            if let message = viewModel.errorText {
                Text(message).foregroundStyle(Color.failedRed).textSelection(.enabled)
                Button("Retry") { viewModel.retryReadFailure() }
            }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Continue") {
                    guard let workflow = viewModel.workflows.first(where: { $0.id == selectedName }) else { return }
                    pendingLaunchName = workflow.id
                    viewModel.selectWorkflow(workflow)
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedName.isEmpty || viewModel.initialLoadingKind != nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(PbRadius.Metrics.spacing28)
        .frame(width: PbRadius.Metrics.workflowLaunchSheetWidth)
    }

    private func finishLoading() {
        guard WorkflowRunnerLaunchPolicy.canLaunch(pendingName: pendingLaunchName, loadedName: viewModel.loadedName,
                                                  loadingKind: viewModel.initialLoadingKind,
                                                  loadFailed: viewModel.initialLoadFailed,
                                                  hasUnsavedChanges: viewModel.hasUnsavedChanges) else { return }
        pendingLaunchName = nil
        viewModel.prepareLaunch()
    }
}

// MARK: - WorkflowRunnerLaunchPolicy

enum WorkflowRunnerLaunchPolicy {
    static func canLaunch(pendingName: String?, loadedName: String, loadingKind: String?, loadFailed: Bool, hasUnsavedChanges: Bool) -> Bool {
        guard let pendingName, !pendingName.isEmpty else { return false }
        return pendingName == loadedName && loadingKind == nil && !loadFailed && !hasUnsavedChanges
    }
}

// MARK: - WorkflowRunnerDraftStore

/// Launching uses only persisted definitions and never restores or alters local editor drafts.
@MainActor
final class WorkflowRunnerDraftStore: WorkflowDraftStoring {
    func load(key: String) throws -> [String: JSONValue]? { nil }
    func save(_ draft: [String: JSONValue], key: String) throws {}
    func remove(key: String) throws {}
}

#if DEBUG
#Preview { WorkflowRunnerView(WorkflowPreview.make()) }
#endif
