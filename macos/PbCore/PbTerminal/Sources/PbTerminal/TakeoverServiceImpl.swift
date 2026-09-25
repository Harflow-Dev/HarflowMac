import Foundation
import MonitorCore
import PbRepository

// MARK: - TakeoverServiceImpl

@MainActor
public final class TakeoverServiceImpl: TakeoverService {

    private let actions: any TaskActionRepository
    private let toolEnvironment: any ToolEnvironmentRepository
    private let taskList: any TaskListRepository
    private let snapshots: any TaskSnapshotRepository
    private let registry: any TerminalSessionRegistry
    private let processRunner: any ProcessRunning
    private let fileManager: FileManager

    public init(
        actions: any TaskActionRepository,
        toolEnvironment: any ToolEnvironmentRepository,
        taskList: any TaskListRepository,
        snapshots: any TaskSnapshotRepository,
        registry: any TerminalSessionRegistry,
        processRunner: any ProcessRunning = ProcessRunner(),
        fileManager: FileManager = .default
    ) {
        self.actions = actions
        self.toolEnvironment = toolEnvironment
        self.taskList = taskList
        self.snapshots = snapshots
        self.registry = registry
        self.processRunner = processRunner
        self.fileManager = fileManager
    }

    // MARK: beginTakeover (AppModel.swift:326-349)

    public func beginTakeover(taskID: String, destination: TakeoverDestination) {
        // Same order as `AppModel.takeover`: busy first, then the locator, and only a located ctl
        // enters busy — so a locator failure never publishes a transient busy state.
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
        Task { [weak self] in
            guard let self else { return }
            defer { self.actions.endBusy(taskID) }
            do {
                let grant = try await actions.takeover(taskID, using: client)
                switch destination {
                case .embedded:
                    openEmbedded(taskID: taskID, grant: grant, client: client)
                case .terminalApp:
                    await openInTerminalApp(taskID: taskID, grant: grant, client: client)
                }
            } catch {
                actions.setOutcome(taskID, Self.message(for: error))
            }
            await taskList.refresh()
            await snapshots.refresh(taskID)
        }
    }

    // MARK: embedded (AppModel.swift:351-388)

    private func openEmbedded(taskID: String, grant: TakeoverGrant, client: CtlClient) {
        let command: TerminalCommand
        do {
            command = try TakeoverWrapper.command(argv: grant.argv, cwd: grant.cwd, environment: toolEnvironment.environment())
        } catch {
            actions.setOutcome(taskID, "The takeover command could not be started: \(error)")
            return
        }
        let session = TerminalSession(
            kind: .takeover(taskID: taskID),
            title: taskList.title(taskID),
            backend: taskList.task(taskID)?.backend ?? "",
            command: command
        )
        session.onStarted = { [weak self, weak session] pid in
            Task { @MainActor in
                guard let self, let session else { return }
                await self.attach(taskID: taskID, pid: pid, session: session, client: client)
            }
        }
        registry.add(session)
        session.start()
    }

    private func attach(taskID: String, pid: pid_t, session: TerminalSession, client: CtlClient) async {
        do {
            try await actions.takeoverAttach(taskID, pid: pid, using: client)
            session.attached = true
            actions.setOutcome(taskID, nil)
        } catch {
            // Without the attach the session is not reserved, so a resume elsewhere could write the
            // same conversation. End the terminal rather than risk two writers, and say it closed
            // only once its exit is confirmed.
            let message = Self.message(for: error)
            session.attachError = message
            actions.setOutcome(taskID, "The takeover could not be attached (\(message)); ending the terminal…")
            session.terminate { [weak self] outcome in
                self?.actions.setOutcome(taskID, Self.attachFailureOutcomeMessage(outcome, attachMessage: message))
            }
        }
    }

    // MARK: Terminal.app (AppModel.swift:390-405)

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

    /// The four exact outcome texts for an attach refusal that ends the terminal
    /// (`AppModel.swift:373-381`), extracted as a pure function so each is a deterministic,
    /// no-process-spawn-needed test.
    static func attachFailureOutcomeMessage(_ outcome: ChildReaper.Outcome, attachMessage: String) -> String {
        switch outcome {
        case .stopped, .alreadyGone:
            "The terminal was closed because the takeover could not be attached: \(attachMessage)"
        case .survived(let pids):
            "The takeover could not be attached and these processes would not exit — end them yourself: "
                + "\(pids.map(String.init).joined(separator: ", ")). \(attachMessage)"
        case .unconfirmed(let pids, let reason):
            "The takeover could not be attached, and the terminal could not be confirmed closed (\(reason))"
                + (pids.isEmpty ? "" : " — check: \(pids.map(String.init).joined(separator: ", "))") + ". \(attachMessage)"
        }
    }
}
