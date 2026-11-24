import AppKit
import HfRepository
import MonitorCore

// MARK: - SidebarRefreshNote

/// The sidebar note shown when a refresh of already listed work fails ("Couldn't refresh your work" with Retry). The last
/// known rows stay and the title bar dot carries the message. Before the first listing the first-listing gate in the main
/// pane owns the failure, and a contract, capability, store or managed-runtime failure belongs to its own gate.
enum SidebarRefreshNote {
    static let title = "Couldn't refresh your work"
    static let retryTitle = "Retry"

    /// Whether another surface (a gate, the managed-runtime banner or the store link) owns the listing error.
    nonisolated static func isOwnedElsewhere(_ listError: ToolError?) -> Bool {
        listError?.isManagedRuntimeUnavailable == true || listError?.isStateRecoveryRefusal == true
            || MainWindowGate.owns(listError)
    }

    /// Pure and safe off the main actor: the note shows for an error on a listing that has already succeeded once.
    nonisolated static func shows(hasListed: Bool, listError: ToolError?) -> Bool {
        hasListed && listError != nil && !isOwnedElsewhere(listError)
    }

    /// SwiftUI on macOS has no status role, so the note is announced when it first shows. `SidebarVM.announce`
    /// calls this once per hidden-to-shown transition of `showsRefreshNote`, never from the row; tests replace it.
    @MainActor static func announce(_ message: String) {
        NSAccessibility.post(element: NSApplication.shared, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }
}
