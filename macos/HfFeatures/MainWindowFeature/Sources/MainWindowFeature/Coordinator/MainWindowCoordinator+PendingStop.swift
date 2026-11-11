import SwiftUI

// MARK: - Pending-launch Stop confirmation

extension MainWindowCoordinator {
    /// Presents the confirmation only over the pending launches destination with the runtime ready and no other
    /// modal. A rejected request is cancelled at once, so the view model never holds a confirmation without a sheet.
    func presentPendingStop(_ request: PendingLaunchStopRequest) {
        guard runtimeIsReady, presentedSheet == nil, selection == .pendingLaunches else {
            request.cancel(.discard)
            return
        }
        // A dismissal callback that never came (the sheet was replaced before it appeared) must not be mistaken for ours.
        awaitingStopDismissal.removeAll()
        pendingStopRequest = request
        presentedSheet = .stopPendingLaunch
    }

    /// Builds the active request's sheet; a missing request renders no controls.
    public func buildPendingLaunchStopView() -> AnyView {
        guard presentedSheet == .stopPendingLaunch, let request = pendingStopRequest else { return AnyView(EmptyView()) }
        return AnyView(PendingLaunchStopConfirmationView(
            taskID: request.taskID,
            onCancel: { [weak self] in self?.cancelPendingStop(requestID: request.id) },
            onConfirm: { [weak self] in self?.confirmPendingStop(requestID: request.id) }
        ))
    }

    func cancelPendingStop(requestID: UUID) {
        guard presentedSheet == .stopPendingLaunch, pendingStopRequest?.id == requestID else { return }
        endPendingStop(reason: .userCancel, closeSheet: true)
    }

    /// Request Stop: the request is released before the sheet closes (so closing it is not a cancel), then the
    /// view model submits once, only while the destination is still shown and the runtime is ready.
    func confirmPendingStop(requestID: UUID) {
        guard presentedSheet == .stopPendingLaunch, let request = pendingStopRequest, request.id == requestID else { return }
        let canConfirm = runtimeIsReady && selection == .pendingLaunches
        pendingStopRequest = nil
        presentedSheet = nil
        if canConfirm { request.confirm() } else { request.cancel(.discard) }
        awaitingStopDismissal.append(request)
    }

    /// The sheet's native `onDismiss`: focus is requested only now, for the request whose sheet was closed.
    public func pendingLaunchStopSheetDidDismiss() {
        guard !awaitingStopDismissal.isEmpty else { return }
        let request = awaitingStopDismissal.removeFirst()
        request.didDismiss(request.id)
    }

    /// The single exit for a request that was not confirmed: the request is cleared first and cancelled exactly once,
    /// and the sheet is closed when asked. The view model hears that the sheet is gone from its native dismissal.
    func endPendingStop(reason: PendingLaunchStopCancelReason, closeSheet: Bool = false) {
        guard let request = pendingStopRequest else { return }
        pendingStopRequest = nil
        request.cancel(reason)
        awaitingStopDismissal.append(request)
        if closeSheet, presentedSheet == .stopPendingLaunch { presentedSheet = nil }
    }
}
