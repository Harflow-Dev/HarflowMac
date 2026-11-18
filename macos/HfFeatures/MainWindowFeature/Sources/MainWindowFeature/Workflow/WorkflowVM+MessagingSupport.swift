import Foundation
import HfRepository
import MonitorCore

// MARK: - WorkflowVM messaging truth

extension WorkflowVM {
    var messagingUnsupported: Bool { messagingSupported == false }

    /// A cancelled run settles every message sent into it as undeliverable, so its lanes lock. A failed run keeps
    /// its messages for recovery, and a completed one is not drawn.
    func applyRunMessageLock() {
        parallel.setWorkflowRunMessageLock(selectedRun?.status == "cancelled")
    }

    /// Probes the runtime once per invocation context. Unknown (`nil`) leaves sending enabled.
    func prepareMessagingSupport() {
        guard didSubscribe, let support = messagingSupport else { return }
        guard let context = try? support.messagingInvocationContext() else {
            messagingSupportRead?.cancel()
            messagingSupportRead = nil
            messagingSupportContext = nil
            setMessagingSupported(nil)
            return
        }
        guard messagingSupportContext != context else { return }
        messagingSupportRead?.cancel()
        messagingSupportContext = context
        setMessagingSupported(nil)
        messagingSupportRead = Task { [weak self] in
            let supported = await support.messagingSupport(context: context)
            guard let self, didSubscribe, !Task.isCancelled, messagingSupportContext == context,
                  support.isMessagingContextCurrent(context) else { return }
            setMessagingSupported(supported)
        }
    }

    func invalidateMessagingSupport() {
        messagingAppearanceID = UUID()
        messagingSupportRead?.cancel()
        messagingSupportRead = nil
        messagingSupportContext = nil
        setMessagingSupported(nil)
    }

    /// Capture before dispatch: an old send cannot replace a new runtime's answer or a later appearance's state.
    func makeMessagingFailureHandler() -> @MainActor (any Error) -> Void {
        let context = try? messagingSupport?.messagingInvocationContext()
        let appearance = messagingAppearanceID
        return { [weak self] error in
            guard let self, didSubscribe, messagingAppearanceID == appearance, let context,
                  messagingSupport?.isMessagingContextCurrent(context) == true,
                  (try? messagingSupport?.messagingInvocationContext()) == context else { return }
            noteMessagingSendFailure(error, context: context)
        }
    }

    /// A current send refused for the missing capability proves the answer faster than the next probe.
    private func noteMessagingSendFailure(_ error: any Error, context: MessagingInvocationContext) {
        guard case .unsupportedCommand(_, _, let detail) = error as? ToolError,
              detail == "Missing capability messaging.v1" else { return }
        messagingSupportRead?.cancel()
        messagingSupportRead = nil
        messagingSupportContext = context
        setMessagingSupported(false)
    }

    private func setMessagingSupported(_ value: Bool?) {
        guard messagingSupported != value else { return }
        messagingSupported = value
        pushMessagingSupport()
    }

    /// Every inspector VM, cached or selected, follows the one answer; a later-created one reads it on creation.
    private func pushMessagingSupport() {
        let unsupported = messagingUnsupported
        selectedActivity?.setMessagingUnsupported(unsupported)
        for activity in activityCache.values { activity.setMessagingUnsupported(unsupported) }
    }
}
