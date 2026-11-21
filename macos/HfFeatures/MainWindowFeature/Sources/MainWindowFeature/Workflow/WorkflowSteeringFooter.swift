import HfUI
import SwiftUI

// MARK: - WorkflowSteeringFooter

/// The root reply remains outside its document and retains captured steering authority.
struct WorkflowSteeringFooter<VM: WorkflowViewModel>: View {
    var viewModel: VM
    var compactCoexistence = false
    var retainedReply = false

    var body: some View {
        let authority = viewModel.steeringAuthority
        VStack(spacing: 0) {
            if viewModel.steeringFailedQueue {
                WorkflowActivityMessageComposer(viewModel: viewModel, showsBubbles: false, queueOnly: true)
            } else {
                MessageBoxView(model: composerModel, isCompact: true, compactWrapper: compactCoexistence,
                    wrapperTopInset: retainedReply ? 4 : nil,
                    text: Binding(get: { viewModel.steeringDraft }, set: { viewModel.steeringDraft = $0 }),
                    onSubmitCompletion: { text, _, completion in
                        viewModel.submitSteering(text, authority: authority)
                        completion(false)
                    }, captureDraftClear: { {} }) { _ in false }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("workflow-steering-composer")
        .fixedSize(horizontal: false, vertical: true)
    }

    private var composerModel: MessageBoxModel {
        let state = viewModel.steering
        return MessageBoxModel(canSend: state.action != nil && !viewModel.steeringRevalidating,
            canContinue: false, isBusy: false, label: "Message the orchestrator", hint: "",
            placeholder: state.placeholder, buttonLabel: "Send", isLocked: state.action == nil,
            showsSendNow: false, allowsDraftEditing: state.action != nil)
    }
}

#if DEBUG
#Preview { WorkflowSteeringFooter(viewModel: WorkflowSteeringPreview.make()) }
#endif
