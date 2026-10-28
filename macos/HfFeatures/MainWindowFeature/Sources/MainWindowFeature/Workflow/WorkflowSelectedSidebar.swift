import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSelectedSidebar

/// Selection activity uses the same retained feed state, paging and viewport leases as Parallel.
struct WorkflowSelectedSidebar<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @Environment(\.viewEvent) private var viewEvent

    var body: some View {
        let state = viewModel.runSidebar
        VStack(spacing: 0) {
            HStack {
                Text(state.title).font(.hf(.body, weight: .semibold))
                Spacer()
                Button("Close", systemImage: "xmark") { viewModel.selectedNodeID = nil }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Show workflow summary")
            }.padding(12)
            if state.attempts.count > 1 {
                Picker("Attempt", selection: Binding(get: { state.activationID ?? "" }, set: { viewModel.selectActivation($0) })) {
                    ForEach(state.attempts) { attempt in Text(attempt.title).tag(attempt.id) }
                }.padding(.horizontal, 12)
            }
            Divider()
            if let raw = state.node, state.isOnDemand {
                DisclosureGroup("Call history · \(state.calls.count) calls") {
                    WorkflowOnDemandCallsView(node: WorkflowNodeModel(raw: raw),
                                              calls: state.calls.map { WorkflowOnDemandCall(raw: $0) }, onOpenTask: viewModel.openOwnerTask)
                        .frame(maxHeight: 220)
                }.padding(12)
                Divider()
            }
            if let native = viewModel.nativeActivity {
                WorkflowNativeActivityView(model: native)
            } else if let child = state.childRunID {
                Button("Open workflow") { viewModel.openRun(child) }.padding(12)
                Spacer()
            } else if let activity = viewModel.selectedActivity {
                WorkflowSelectedActivityView(activity: activity)
                .id(ObjectIdentifier(activity))
                .publishViewEvent(from: activity, to: viewEvent)
            } else {
                ContentUnavailableView(state.attempts.isEmpty ? "Not started" : "No task activity", systemImage: "text.alignleft")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.cardFill)
        .accessibilityIdentifier("workflow-selected-sidebar")
    }
}

#if DEBUG
#Preview { WorkflowSelectedSidebar(viewModel: WorkflowPreview.make(run: true)) }
#endif
