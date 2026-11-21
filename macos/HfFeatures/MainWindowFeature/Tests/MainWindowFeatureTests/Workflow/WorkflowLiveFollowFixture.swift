import AppKit
import HfUI
@testable import MainWindowFeature
import SwiftUI

@MainActor struct WorkflowLiveFollowFixture: View {
    @ObservedObject var model: WorkflowLiveFollowFixtureModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showActivity {
                let callbackVersion = model.callbackVersion
                WorkflowNativeActivityView(model: model.activity, messages: model.messages, onCancel: { id in
                    model.cancelledMessageID = id
                    model.cancelCallbackVersion = callbackVersion
                }, leadingContent: model.callSelectorRows, callReveal: model.callReveal,
                   onCallScrollAcknowledged: model.acknowledgeCallScroll)
                    .id(model.executionID)
            }
            MessageBoxView(model: model.composerEnabled ? MessageBoxModel(
                canSend: true, canContinue: false, isBusy: false, label: "Messages",
                hint: "", placeholder: "Write a message", buttonLabel: "Send"
            ) : .disabled) { _ in true }
        }
        .background(Text("\(model.refresh)").hidden())
        .environment(\.colorScheme, model.colorScheme)
        .frame(width: model.fixedWidth)
        .frame(minWidth: model.fixedWidth == nil ? 220 : 0, minHeight: 280)
    }
}
