import AppKit
import MonitorCore
import SwiftTerm
import SwiftUI

/// One embedded terminal the app started: a take-over of a task's session, or a new interactive
/// session. The terminal view lives as long as the session, so switching tabs never restarts it.
@MainActor
final class TerminalSession: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case takeover(taskID: String)
        case interactive
    }

    let id = UUID()
    let kind: Kind
    let title: String
    let backend: String
    let command: TerminalCommand
    let startedAt = Date()
    @Published private(set) var pid: pid_t?
    @Published private(set) var ended = false
    @Published private(set) var exitStatus: WaitStatus?
    @Published var attached = false
    @Published var attachError: String?
    @Published private(set) var size = "—"

    var onStarted: ((pid_t) -> Void)?
    var onEnded: (() -> Void)?

    let view: LocalProcessTerminalView
    private let delegate: Delegate

    init(kind: Kind, title: String, backend: String, command: TerminalCommand) {
        self.kind = kind
        self.title = title
        self.backend = backend
        self.command = command
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 900, height: 560))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        delegate = Delegate()
        delegate.session = self
        view.processDelegate = delegate
    }

    func start() {
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
    func terminate(completion: ((ChildReaper.Outcome) -> Void)? = nil) {
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
                        self.attachError = (self.attachError.map { $0 + "\n" } ?? "") + "These processes did not exit even after SIGKILL: \(pids.map(String.init).joined(separator: ", "))."
                    case .unconfirmed(let pids, let reason):
                        self.attachError = (self.attachError.map { $0 + "\n" } ?? "") + "Could not confirm the terminal's processes stopped (\(reason))" + (pids.isEmpty ? "." : ": \(pids.map(String.init).joined(separator: ", ")).")
                    }
                    let waiters = self.terminationWaiters
                    self.terminationWaiters = []
                    waiters.forEach { $0(outcome) }
                }
            }
        }
    }

    @Published private(set) var terminating = false
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

    var statusLine: String {
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
            let session = self.session
            DispatchQueue.main.async {
                MainActor.assumeIsolated { session?.processExited(rawStatus: exitCode) }
            }
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session.view, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
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
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

struct TerminalPane: View {
    @ObservedObject var session: TerminalSession
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            TerminalHost(session: session)
                .background(Color.black)
            Divider()
            HStack(spacing: 14) {
                Text(session.statusLine)
                Text("zsh · \(session.size)").monospacedDigit()
                if let pid = session.pid { Text("pid \(pid)").monospacedDigit() }
                if case .takeover = session.kind {
                    // Once the process is gone polybridge releases the reservation; never claim it then.
                    if session.ended {
                        Text(session.attached ? "ended · reservation released" : "ended").foregroundStyle(.secondary)
                    } else {
                        Text(session.attached ? "session reserved" : (session.attachError == nil ? "attaching…" : "not attached"))
                            .foregroundStyle(session.attached ? Color.doneGreen : Color.failedRed)
                    }
                }
                Spacer()
                if session.ended {
                    Button("Close") { model.removeSession(session) }
                } else {
                    Button(session.terminating ? "Ending…" : "End session") { session.terminate() }
                        .disabled(session.terminating)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            if let error = session.attachError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color.failedRed).padding(8)
            }
        }
    }
}
