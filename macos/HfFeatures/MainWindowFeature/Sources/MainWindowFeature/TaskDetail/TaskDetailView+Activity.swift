import HfUI
import MonitorCore
import SwiftUI

// MARK: - TaskDetailView Activity

extension TaskDetailView {
    /// Content over the composer. The feed centres its own content with `readingColumn()` inside its
    /// scroll view (settled plan D13), so scrollbars sit at the pane's edge.
    var column: some View {
        VStack(spacing: HfRadius.Metrics.zero) {
            content
            MessageBoxView(model: viewModel.messageBoxModel, onSubmitNow: viewModel.submitMessageNow,
                           wrapperTopInset: chrome == .builder ? nil : HfRadius.Metrics.spacing4,
                           style: transcriptStyle.isTranscript ? .transcript : .standard,
                           text: isStandalone ? draftMount?.text : nil,
                           onSubmitCompletion: viewModel.submitMessage,
                           captureDraftClear: draftMount.map { mount in { mount.captureAcceptedDraftClear() } }) { text in viewModel.submitMessage(text) }
                .readingColumn()
        }
    }

    /// The builder column's feed never collapses below this, so the conversation stays scrollable at the minimum window.
    static var builderFeedMinimumHeight: CGFloat { 80 }

    var content: some View {
        VStack(spacing: 0) {
            StoredRequestView(state: viewModel.requestReadState, read: viewModel.didReadRequest, copy: viewModel.didCopyObservationText)
                .padding(16)
            standaloneProvenanceLine
            ForEach(viewModel.orderedHistoryFrames, id: \.taskID) { frame in
                ObservationHistoryView(frame: frame) { viewModel.didRequestObservation($0, taskID: frame.taskID) }
                    .padding(.horizontal, 16)
.padding(.bottom, 8)
            }
            if let feedback = viewModel.copyFeedback { Text(feedback).font(.hf(.caption)).textSelection(.enabled) }
            TimelinePaneView(model: viewModel.timelineModel, state: activityState, approvalController: viewModel.callerApprovalController,
                             isCancelDisabled: viewModel.continuationPresentation?.locksActions == true || viewModel.isBusy
                                 || (chrome == .standalone && !viewModel.hasStatusAuthority), style: transcriptStyle,
                             composerEdge: chrome != .builder,
                             composerEdgeUsesWindowBackground: chrome != .builder && !transcriptStyle.isTranscript,
                             stateTreatment: isStandalone ? viewModel.stateTreatment : nil,
                             onStateContinue: viewModel.didTapContinue,
                             onStateCheck: viewModel.didTapCheckContinuation, onStateNewTask: viewModel.didTapNewTask,
                             onStateStop: viewModel.didTapCancel, onStateRefresh: viewModel.didTapRefreshState,
                             onStateCopyResumeCommand: viewModel.didTapCopyResumeCommand,
                             onStateOpenEvents: { pane.animated { pane.select(.events) } },
                             feedMinimumHeight: chrome == .builder ? Self.builderFeedMinimumHeight : nil)
        }
    }

}
