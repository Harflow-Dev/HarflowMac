import Foundation
import MonitorCore

// MARK: - TakeoverServiceImpl

/// Opens a task's session in Terminal.app — see `TakeoverService`'s doc for the flow. Stateless
/// orchestration over its dependencies: busy and the outcome line live in `TaskActionRepository`, so
/// this service has no mutable state of its own to protect, and no lock/actor is needed.
public final class TakeoverServiceImpl: TakeoverService, @unchecked Sendable {

    private let actions: any TaskActionRepository
    private let toolEnvironment: any ToolEnvironmentRepository
    private let taskList: any TaskListRepository
    private let snapshots: any TaskSnapshotRepository
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager

    public init(
        actions: any TaskActionRepository,
        toolEnvironment: any ToolEnvironmentRepository,
        taskList: any TaskListRepository,
        snapshots: any TaskSnapshotRepository,
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.actions = actions
        self.toolEnvironment = toolEnvironment
        self.taskList = taskList
        self.snapshots = snapshots
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    // MARK: beginTakeover

    public func beginTakeover(taskID: String) {
        // Busy first, then the locator, and only a located ctl enters busy — so a locator failure
        // never publishes a transient busy state.
        guard !actions.busy.contains(taskID) else { return }
        let client: CtlClient
        switch toolEnvironment.ctl() {
        case .failure(let error):
            actions.setOutcome(taskID, error.message)
            return
        case .success(let located):
            client = located
        }
        guard actions.tryBeginBusy(taskID) else { return }
        actions.setOutcome(taskID, "Stopping the headless run and reserving the session…")
        // Captured strongly on purpose: the handoff owns itself. Busy has already been entered, so a
        // task that found its service gone would leave the task stuck busy with no outcome.
        Task { [self] in
            defer { self.actions.endBusy(taskID) }
            do {
                let grant = try await actions.takeover(taskID, using: client)
                await openInTerminalApp(taskID: taskID, grant: grant, client: client)
            } catch {
                actions.setOutcome(taskID, Self.message(for: error))
            }
            await taskList.refresh()
            await snapshots.refresh(taskID)
        }
    }

    // MARK: Terminal.app

    private func openInTerminalApp(taskID: String, grant: TakeoverGrant, client: CtlClient) async {
        do {
            let files = try TerminalAppHandoff.files(ctl: client.executable, taskID: taskID, grant: grant)
            let parent = fileManager.temporaryDirectory.appendingPathComponent("PolybridgeMonitor", isDirectory: true)
            try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let script = try TerminalAppHandoff.write(files, under: parent)
            let result = await processRunner.run(
                executable: "/usr/bin/open", arguments: ["-a", "Terminal", script.path],
                environment: toolEnvironment.environment(), currentDirectory: nil, timeout: 15
            )
            if case .success(let output) = result, output.exitCode == 0 {
                actions.setOutcome(taskID, "Opened in Terminal.app. It attaches itself before starting; if it cannot, it refuses to start the session.")
            } else {
                actions.setOutcome(taskID, "Terminal.app could not be opened. The takeover lapses unattached in 120 s.")
            }
        } catch {
            actions.setOutcome(taskID, "The Terminal.app hand-off could not be written: \(error.localizedDescription)")
        }
    }

    private static func message(for error: Error) -> String {
        (error as? ToolError)?.message ?? "\(error)"
    }
}
