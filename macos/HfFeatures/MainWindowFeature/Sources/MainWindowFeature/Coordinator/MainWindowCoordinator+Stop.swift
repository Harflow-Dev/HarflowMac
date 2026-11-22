import AppKit
import SwiftUI

// MARK: - Standalone Stop confirmation

extension MainWindowCoordinator {
    func discardTaskStopFocus() {
        cancelledTaskStop = nil
        taskStopDismissals.removeAll()
    }

    func discardStopForRuntimeLoss() {
        discardTaskStopFocus()
        presentedSheet = nil
    }

    func presentStopConfirmation(_ confirmation: TaskStopConfirmation) {
        guard runtimeIsReady, presentedSheet == nil,
              shownTaskConversation() == normalisedConversationID(for: confirmation.conversationID) else { return }
        cancelledTaskStop = nil
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
        }, onCancel: { [weak self] in
            self?.cancelStop(requestID: confirmation.id)
        }).background(TaskStopSheetAttachment { [weak self] window in
            self?.observeTaskStopDismissal(requestID: confirmation.id, window: window)
        }))
    }

    private func observeTaskStopDismissal(requestID: UUID, window: NSWindow) {
        guard presentedSheet == .stopTask, stopConfirmation?.id == requestID,
              taskStopDismissals[requestID] == nil else { return }
        taskStopDismissals[requestID] = TaskStopSheetDismissal(window: window) { [weak self] in
            guard let self else { return }
            if cancelledTaskStop?.id == requestID { taskStopSheetDidDismiss(requestID: requestID) }
        }
    }

    public func dismissPresentedSheet() {
        if presentedSheet == .stopTask, let id = stopConfirmation?.id {
            cancelStop(requestID: id)
        } else { presentedSheet = nil }
    }

    func cancelStop(requestID: UUID) {
        guard presentedSheet == .stopTask, let confirmation = stopConfirmation,
              confirmation.id == requestID else { return }
        cancelledTaskStop = confirmation
        presentedSheet = nil
        // Native Escape may detach the sheet before SwiftUI writes its nil binding.
        if taskStopDismissals[requestID]?.isDetached == true { taskStopSheetDidDismiss(requestID: requestID) }
    }

    /// Only the exact sheet's native dismissal can consume a cancelled request.
    func taskStopSheetDidDismiss(requestID: UUID) {
        guard let confirmation = cancelledTaskStop, confirmation.id == requestID else { return }
        cancelledTaskStop = nil
        taskStopDismissals[requestID] = nil
        guard presentedSheet == nil, runtimeIsReady,
              shownTaskConversation() == normalisedConversationID(for: confirmation.conversationID) else { return }
        confirmation.cancelDidDismiss?()
    }

    func confirmStop(requestID: UUID) {
        guard presentedSheet == .stopTask, let confirmation = stopConfirmation,
              confirmation.id == requestID else { return }
        let canConfirm = runtimeIsReady
            && shownTaskConversation() == normalisedConversationID(for: confirmation.conversationID)
        cancelledTaskStop = nil
        taskStopDismissals.removeAll()
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
