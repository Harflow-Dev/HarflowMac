import HfCommon
import MonitorCore
import SwiftUI

// MARK: - MonitorCommands

/// App-wide commands remain available when the main window or workflow editor is closed.
struct MonitorCommands: Commands {
    let coordinator: AppCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { coordinator.handle(path: MonitorDestination.newSession) }
                .keyboardShortcut("n")
                .disabled(coordinator.mainWindowNavigationCoordinator?.workIsAvailable == false)
            Button("Create Workflow…") { coordinator.createWorkflow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(coordinator.mainWindowNavigationCoordinator?.workIsAvailable == false)
            Button("Run Workflow…") { coordinator.runWorkflow() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(coordinator.mainWindowNavigationCoordinator?.workIsAvailable == false)
        }
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
        }
    }
}
