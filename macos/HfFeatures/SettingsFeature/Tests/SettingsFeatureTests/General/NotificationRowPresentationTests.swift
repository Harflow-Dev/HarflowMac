import Foundation
import HfRepository
@testable import SettingsFeature
import Testing

@Suite struct NotificationRowPresentationTests {
    private struct Expected {
        let feed: NotificationFeedAvailability
        let permission: NotificationAuthorization?
        let state: NotificationRowPresentation.State?
        let detail: String?
        let switchesEnabled: Bool
        let actionTitle: String?
    }

    private let unavailableSentence = "This Harflow runtime can't send notifications. Update Harflow to use it."
    private let notRequested = "macOS asks the first time Harflow sends a notification."
    private let denied = "Notifications are off for Harflow in System Settings. The two switches above have no effect until you allow them."
    private let allowed = "Notifications are allowed for Harflow."

    @Test func givenEveryRowOfTheStateTable_whenPresenting_thenCopySwitchesAndButtonFollowTheDesign() {
        // given
        let cases: [Expected] = [
            Expected(feed: .unavailable, permission: .allowed, state: .unavailable, detail: unavailableSentence, switchesEnabled: false, actionTitle: nil),
            Expected(feed: .unavailable, permission: .denied, state: .unavailable, detail: unavailableSentence, switchesEnabled: false, actionTitle: nil),
            Expected(
                feed: .unavailable, permission: .notDetermined, state: .unavailable, detail: unavailableSentence,
                switchesEnabled: false, actionTitle: nil
            ),
            Expected(feed: .unavailable, permission: nil, state: nil, detail: nil, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .available, permission: .notDetermined, state: .notRequested, detail: notRequested, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .unknown, permission: .notDetermined, state: .notRequested, detail: notRequested, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .available, permission: .denied, state: .denied, detail: denied, switchesEnabled: false, actionTitle: "Open System Settings"),
            Expected(feed: .unknown, permission: .denied, state: .denied, detail: denied, switchesEnabled: false, actionTitle: "Open System Settings"),
            Expected(feed: .available, permission: .allowed, state: .allowed, detail: allowed, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .unknown, permission: .allowed, state: .allowed, detail: allowed, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .available, permission: nil, state: nil, detail: nil, switchesEnabled: true, actionTitle: nil),
            Expected(feed: .unknown, permission: nil, state: nil, detail: nil, switchesEnabled: true, actionTitle: nil)
        ]

        for expected in cases {
            // when
            let row = NotificationRowPresentation.row(permission: expected.permission, feed: expected.feed)

            // then
            #expect(row?.state == expected.state)
            #expect(row?.title == (expected.state == nil ? nil : "Notifications"))
            #expect(row?.detail == expected.detail)
            #expect(row?.actionTitle == expected.actionTitle)
            #expect(row?.switchesEnabled ?? true == expected.switchesEnabled)
        }
    }

    @Test func givenABundleIdentifier_whenBuildingTheSettingsLink_thenItNamesTheAppsPane() {
        // given / when
        let url = NotificationRowPresentation.settingsURL(bundleIdentifier: "dev.harflow.app")

        // then
        #expect(url?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=dev.harflow.app")
    }

    @Test func givenNoBundleIdentifier_whenBuildingTheSettingsLink_thenItOpensTheNotificationsPane() {
        // given / when
        let url = NotificationRowPresentation.settingsURL(bundleIdentifier: nil)

        // then
        #expect(url?.absoluteString == "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
    }
}
