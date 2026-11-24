import Foundation
import HfRepository
import Mockable

// MARK: - NotificationSettingsRouting

/// Opens the system's notification settings for Harflow.
@Mockable
@MainActor
protocol NotificationSettingsRouting: Sendable {
    func openNotificationSettings()
}

// MARK: - NotificationRowPresentation

/// The Notifications row of the Behaviour group (HarflowDesign `8ec4d38`, `settings/notifications-*`).
struct NotificationRowPresentation: Equatable, Sendable {
    enum State: Equatable, Sendable {
        case notRequested, denied, allowed, unavailable
    }

    let state: State

    var title: String { "Notifications" }

    var detail: String {
        switch state {
        case .unavailable: MissingFeature.sentence(canDo: "send notifications")
        case .notRequested: "macOS asks the first time Harflow sends a notification."
        case .denied: "Notifications are off for Harflow in System Settings. The two switches above have no effect until you allow them."
        case .allowed: "Notifications are allowed for Harflow."
        }
    }

    var actionTitle: String? { state == .denied ? "Open System Settings" : nil }

    /// Whether the two notify switches have any effect.
    var switchesEnabled: Bool { state != .denied && state != .unavailable }

    /// Nil when the app cannot post at all, whatever the feed. A runtime without the feed wins over a denied permission.
    nonisolated static func row(permission: NotificationAuthorization?, feed: NotificationFeedAvailability) -> Self? {
        guard let permission else { return nil }
        if feed == .unavailable { return Self(state: .unavailable) }
        switch permission {
        case .notDetermined: return Self(state: .notRequested)
        case .denied: return Self(state: .denied)
        case .allowed: return Self(state: .allowed)
        }
    }

    private nonisolated static let queryValueAllowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?/"))

    /// The deep link is undocumented, so without a bundle identifier it opens the Notifications pane itself.
    nonisolated static func settingsURL(bundleIdentifier: String?) -> URL? {
        let pane = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        guard let bundleIdentifier, let id = bundleIdentifier.addingPercentEncoding(withAllowedCharacters: Self.queryValueAllowed) else {
            return URL(string: pane)
        }
        return URL(string: pane + "?id=" + id)
    }
}
