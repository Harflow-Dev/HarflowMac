import HfCommon
import HfUI
import MonitorCore
import SwiftUI

// MARK: - WorkflowSelectedSidebar

/// Selection activity uses the same retained feed state, paging and viewport leases as Parallel.
struct WorkflowSelectedSidebar<VM: WorkflowViewModel>: View {
    var viewModel: VM
    @Environment(\.viewEvent) private var viewEvent

    @State private var paneHeight: CGFloat = 0
    /// Measured chrome kept out of the feed's floor: the head block, the fallback composer and the inspector column's own chrome.
    @State private var headBlockHeight: CGFloat = 0
    @State private var composerHeight: CGFloat = 0
    @State private var columnChrome: CGFloat = 0

    var body: some View {
        let state = viewModel.runSidebar
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                WorkflowSelectedHead(viewModel: viewModel)
                if state.attempts.count > 1, !state.isOnDemand {
                    Picker("Attempt", selection: Binding(get: { state.activationID ?? "" }, set: { viewModel.selectActivation($0) })) {
                        ForEach(state.attempts) { attempt in Text(attempt.title).tag(attempt.id) }
                    }.padding(.horizontal, 12)
                }
                Divider()
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headBlockHeight = $0 }
            topRegion(state)
            if let native = viewModel.nativeActivity {
                WorkflowNativeActivityView(model: native, messages: viewModel.activityMessageBubbles,
                                            onCancel: viewModel.cancelActivityMessage,
                                            isCancelDisabled: viewModel.isBusy)
                    .id(native.executionID)
            } else if let child = state.childRunID {
                Button("Open workflow") { viewModel.openRun(child) }.padding(12)
                Spacer()
            } else if let activity = viewModel.selectedActivity {
                WorkflowSelectedActivityView(activity: activity, unavailableDetails: unavailableDetails(state, activity),
                                             showsTaskTitle: state.header.kind == .orchestrator)
                .id(ObjectIdentifier(activity))
                .publishViewEvent(from: activity, to: viewEvent)
            } else if WorkflowCallDetails.isShown(isOnDemand: state.isOnDemand, hasDetails: state.callDetails != nil,
                                                  hasActivity: false, activityShowsConversation: false), let details = state.callDetails {
                WorkflowCallDetailsView(details: details)
            } else {
                ContentUnavailableView(state.attempts.isEmpty ? "Not started" : "No task activity", systemImage: "text.alignleft")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if showsFallbackComposer(state) {
                WorkflowActivityMessageComposer(viewModel: viewModel, showsBubbles: viewModel.nativeActivity == nil)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { composerHeight = $0 }
            }
        }
        .onPreferenceChange(WorkflowSelectedColumnChromeKey.self) { columnChrome = $0 }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { paneHeight = $0 }
        .background(TaskScreenStyle.Colors.pageBackground.color)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-selected-sidebar")
    }

    /// The region above the transcript: the goal and caption of a worker, or an on-demand node's intro and calls.
    @ViewBuilder
    private func topRegion(_ state: WorkflowRunSidebarPresentation) -> some View {
        let reserved = headBlockHeight + (showsFallbackComposer(state) ? composerHeight : 0) + columnChrome + ParallelLayout.dividerWidth
        switch state.header.kind {
        case .worker:
            if state.showsGoal || state.caption != nil {
                WorkflowSelectedScrollRegion(paneHeight: paneHeight, reserved: reserved) {
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
                        if state.showsGoal, let run = viewModel.selectedRun { WorkflowGoalView(viewModel: viewModel, run: run) }
                        if let caption = state.caption { captionText(caption) }
                    }.padding(HfRadius.Metrics.spacing16)
                }
                Divider()
            }
        case .onDemand:
            WorkflowSelectedScrollRegion(paneHeight: paneHeight, reserved: reserved) {
                VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing16) {
                    Text("Runs only when the orchestrator calls it, one call at a time.")
                        .font(.hf(.secondary))
.foregroundStyle(Color.secondaryText)
                    VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing8) {
                        Text("CALLS").font(.hf(.caption, weight: .semibold)).foregroundStyle(Color.tertiaryText)
                        if state.callRows.isEmpty {
                            captionText("Not called yet.")
                        } else {
                            WorkflowOnDemandCallList(rows: state.callRows, selectedID: state.activationID,
                                                     onSelect: viewModel.selectActivation, onOpenTask: viewModel.openOwnerTask)
                        }
                    }
                    if let caption = state.caption, !state.callRows.isEmpty {
                        Divider()
                        captionText(caption)
                    }
                }.padding(HfRadius.Metrics.spacing16)
            }
            Divider()
        case .orchestrator:
            EmptyView()
        }
    }

    /// The pane's own composer: shown while no inspector column (with its own composer) is on screen.
    private func showsFallbackComposer(_ state: WorkflowRunSidebarPresentation) -> Bool {
        viewModel.nativeActivity != nil || state.childRunID != nil
            || viewModel.selectedActivity == nil || viewModel.selectedActivity?.columns.isEmpty == true
    }

    /// The call's details when its activity exists but cannot show the conversation, so they stay reachable.
    private func unavailableDetails(_ state: WorkflowRunSidebarPresentation, _ activity: ParallelVM) -> WorkflowCallDetails? {
        let shows = activity.columns.contains { $0.id == activity.selectedConversationID }
        return WorkflowCallDetails.isShown(isOnDemand: state.isOnDemand, hasDetails: state.callDetails != nil,
                                           hasActivity: true, activityShowsConversation: shows) ? state.callDetails : nil
    }

    private func captionText(_ value: String) -> some View {
        Text(value).font(.hf(.caption)).foregroundStyle(Color.tertiaryText).textSelection(.enabled)
    }
}

#if DEBUG
#Preview { WorkflowSelectedSidebar(viewModel: WorkflowPreview.make(run: true)) }

#Preview("Workflow selected sidebar - not started") {
    WorkflowSelectedSidebar(viewModel: WorkflowPreview.makeNotStartedNodeRun())
}
#endif
