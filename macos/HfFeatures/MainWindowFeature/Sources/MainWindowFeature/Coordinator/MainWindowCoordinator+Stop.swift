import SwiftUI

// MARK: - Standalone Stop confirmation

extension MainWindowCoordinator {
    func presentStopConfirmation(_ confirmation: TaskStopConfirmation) {
        guard runtimeIsReady, presentedSheet == nil,
              shownTaskConversation() == normalisedConversationID(for: confirmation.conversationID) else { return }
        stopConfirmation = confirmation
        presentedSheet = .stopTask
    }

    /// Builds the active captured Stop request; missing requests render no controls.
    public func buildStopConfirmationView() -> AnyView {
        guard presentedSheet == .stopTask, let confirmation = stopConfirmation else {
            return AnyView(EmptyView())
        }
        return AnyView(TaskStopConfirmationView(confirmation: confirmation, onConfirm: { [weak self] in
            self?.confirmStop(requestID: confirmation.id)
        }))
    }

    func confirmStop(requestID: UUID) {
        guard presentedSheet == .stopTask, let confirmation = stopConfirmation,
              confirmation.id == requestID else { return }
        let canConfirm = runtimeIsReady
            && shownTaskConversation() == normalisedConversationID(for: confirmation.conversationID)
        presentedSheet = nil
        guard canConfirm else { return }
        confirmation.confirm()
    }

    func discardStopConfirmationIfConversationChanged() {
        guard let confirmation = stopConfirmation,
              shownTaskConversation() != normalisedConversationID(for: confirmation.conversationID) else { return }
        presentedSheet = nil
    }
}
