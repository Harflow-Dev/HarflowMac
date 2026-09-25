import AppKit
import MonitorCore
import SwiftUI
@preconcurrency import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var launchedAt = Date()
    private var launchedByURL = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launchedAt = Date()
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
        }
        MainActor.assumeIsolated { AppModel.shared.start() }
        // SwiftUI opens the main window at launch. When the launch came from a task starting
        // (`open -g polybridge-monitor://task/<id>`) and the user asked not to have the window
        // come forward, put it away again; a launch by hand keeps it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [self] in
            MainActor.assumeIsolated {
                guard launchedByURL, !AppModel.shared.openWindowOnStart else { return }
                for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
                    window.orderOut(nil)
                }
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if Date().timeIntervalSince(launchedAt) < 2 { launchedByURL = true }
        MainActor.assumeIsolated {
            for url in urls { AppModel.shared.handle(url: url) }
        }
    }

    // A menu-bar app keeps running with its window closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["task_id"] as? String, MonitorURL.isValidTaskID(id) {
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    AppModel.shared.selection = .task(id)
                    AppModel.shared.showWindow()
                }
            }
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct PolybridgeMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        Window("Polybridge Monitor", id: "main") {
            MainView().environmentObject(model)
        }
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Session…") { model.showNewSession = true }.keyboardShortcut("n")
            }
        }

        MenuBarExtra {
            MenuBarView().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}
