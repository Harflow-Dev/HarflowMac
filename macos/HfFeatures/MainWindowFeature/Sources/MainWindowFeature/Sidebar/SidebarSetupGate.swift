import HfRepository
import MonitorCore

// MARK: - SidebarSetupGate

/// Whether the sidebar's setup line replaces its body.
enum SidebarSetupGate {
    /// The setup line shows while the runtime is not ready, or while a contract or capability gate owns the listing
    /// error. A failed update keeps the installed runtime, so once something has been listed the populated sidebar
    /// stays, with creation blocked by `SidebarVM.creationIsAvailable`. Under the pinned engine nothing is listed
    /// before a failed update, so that branch is not reachable today.
    nonisolated static func applies(setupState: RuntimeSetupState, hasListed: Bool, listError: ToolError?) -> Bool {
        if case .updateFailed = setupState { return !hasListed || MainWindowGate.owns(listError) }
        return !setupState.isReady || MainWindowGate.owns(listError)
    }
}
