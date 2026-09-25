import AppKit
import MonitorCore
@preconcurrency import SwiftTerm
import SwiftUI

// MARK: - TerminalSession

/// One embedded terminal the app started: a take-over of a task's session, or a new interactive
/// session. The terminal view lives as long as the session, so switching tabs never restarts it.
@MainActor
public final class TerminalSession: ObservableObject, Identifiable {

    /// What this terminal is for: a task the app took over, or a brand-new interactive session.
    public enum Kind: Equatable {
        case takeover(taskID: String)
        case interactive
    }

    public let id = UUID()
    public let kind: Kind
    public let title: String
    public let backend: String
    public let command: TerminalCommand
    public let startedAt = Date()
    @Published public private(set) var pid: pid_t?
    @Published public private(set) var ended = false
    @Published public private(set) var exitStatus: WaitStatus?
    @Published public internal(set) var attached = false
    @Published public internal(set) var attachError: String?
    @Published public private(set) var size = "—"

    /// Fires once, right after the child was successfully adopted (never on a `ChildAdoption`
    /// failure — see `start()`).
    public var onStarted: ((pid_t) -> Void)?
    /// Fires once, the first time the session is marked ended (`markEnded()` is idempotent).
    public var onEnded: (() -> Void)?

    let view: LocalProcessTerminalView
    private let delegate: Delegate

    public init(kind: Kind, title: String, backend: String, command: TerminalCommand) {
        self.kind = kind
        self.title = title
        self.backend = backend
        self.command = command
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        self.delegate = Delegate()
        delegate.session = self
        view.processDelegate = delegate
    }

    public func start() {
        // The executable and each argument go to the pty child as they are: an argv array, never
        // a command string (see `TakeoverWrapper`).
        view.startProcess(
            executable: command.executable,
            args: command.arguments,
            environment: LaunchEnvironment.asList(command.environment),
            execName: nil,
            currentDirectory: command.currentDirectory
        )
        let child = view.process.shellPid
        guard child > 0 else {
            ended = true
            attachError = "The terminal process could not be started."
            return
        }
        switch ChildAdoption.adopt(child) {
        case .success(let found):
            pid = child
            identity = found
            onStarted?(child)
        case .failure:
            // Never attached, never reserved: it must not keep running (see ChildAdoption).
            pid = child
            ended = true
            attachError = "The terminal's process \(child) could not be identified, so it was stopped rather than left running without a reservation."
        }
    }

    /// Ends the process this session started — and its process group — and calls back once none of
    /// them is alive. Never uses SwiftTerm's `terminate()`, which signals the pid unchecked; see
    /// `ChildReaper`. A request while one is in flight joins it — checked before `ended`, since the
    /// leader can exit (setting `ended`) while its group is still being cleaned up. It also runs
    /// after the leader has exited, because the group may outlive it.
    public func terminate(completion: ((ChildReaper.Outcome) -> Void)? = nil) {
        if terminating {
            if let completion { terminationWaiters.append(completion) }
            return
        }
        guard let identity else {
            completion?(.alreadyGone)
            return
        }
        if let completion { terminationWaiters.append(completion) }
        terminating = true
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ChildReaper.terminate(identity)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.terminating = false
                    switch outcome {
                    case .stopped, .alreadyGone:
                        self.markEnded()
                    case .survived(let pids):
                        self.attachError = (self.attachError.map { $0 + "\n" } ?? "")
                            + "These processes did not exit even after SIGKILL: \(pids.map(String.init).joined(separator: ", "))."
                    case .unconfirmed(let pids, let reason):
                        self.attachError = (self.attachError.map { $0 + "\n" } ?? "")
                            + "Could not confirm the terminal's processes stopped (\(reason))"
                            + (pids.isEmpty ? "." : ": \(pids.map(String.init).joined(separator: ", ")).")
                    }
                    let waiters = self.terminationWaiters
                    self.terminationWaiters = []
                    waiters.forEach { $0(outcome) }
                }
            }
        }
    }

    @Published public private(set) var terminating = false
    private var terminationWaiters: [(ChildReaper.Outcome) -> Void] = []
    /// (pid, start time) of the child, read right after spawn — what every signal is checked against.
    private(set) var identity: ProcessIdentity?

    private func markEnded() {
        guard !ended else { return }
        ended = true
        onEnded?()
    }

    /// From SwiftTerm's exit monitor, with the raw `waitpid` status.
    fileprivate func processExited(rawStatus: Int32?) {
        if let rawStatus { exitStatus = WaitStatus(raw: rawStatus) }
        markEnded()
    }

    fileprivate func resized(cols: Int, rows: Int) {
        size = "\(cols)×\(rows)"
    }

    public var statusLine: String {
        if ended { return "Session ended" + (exitStatus.map { " · \($0.label)" } ?? "") }
        return "\(backend.isEmpty ? "shell" : backend) · interactive, runs under your own permissions"
    }

    private final class Delegate: NSObject, LocalProcessTerminalViewDelegate {
        weak var session: TerminalSession?

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {
            MainActor.assumeIsolated { session?.resized(cols: newCols, rows: newRows) }
        }

        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            let session = session
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session?.processExited(rawStatus: exitCode) }
            }
        }
    }
}

// MARK: - TerminalHost

/// Reparents the session's `NSView` and makes it first responder. The view lives with the session,
/// not the host, so switching tabs (which recreates `TerminalHost`) never restarts the process.
public struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    public init(session: TerminalSession) {
        self.session = session
    }

    public func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session.view, to: container)
        return container
    }

    public func updateNSView(_ container: NSView, context: Context) {
        if session.view.superview !== container { attach(session.view, to: container) }
    }

    private func attach(_ view: NSView, to container: NSView) {
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}
