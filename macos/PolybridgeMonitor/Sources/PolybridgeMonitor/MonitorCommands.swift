import MonitorCore
import PbCommon
import SwiftUI

// MARK: - MonitorCommands

/// App-wide commands remain available when the main window or workflow editor is closed.
struct MonitorCommands: Commands {
    let coordinator: AppCoordinator

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Session…") { coordinator.handle(path: MonitorDestination.newSession) }
                .keyboardShortcut("n")
            Button("Create Workflow…") { coordinator.createWorkflow() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Run Workflow…") { coordinator.runWorkflow() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",")
        }
    }
}
