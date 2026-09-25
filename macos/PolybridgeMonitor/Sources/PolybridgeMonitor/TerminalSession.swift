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
    @Published private(set) var exitCode: Int32?
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
        if child > 0 {
            pid = child
            onStarted?(child)
        } else {
            ended = true
            attachError = "The terminal process could not be started."
        }
    }

    /// Ends only the process this session started, by its own pid.
    func terminate() {
        guard !ended else { return }
        view.terminate()
    }

    fileprivate func processEnded(_ code: Int32?) {
        ended = true
        exitCode = code
        onEnded?()
    }

    fileprivate func resized(cols: Int, rows: Int) {
        size = "\(cols)×\(rows)"
    }

    var statusLine: String {
        if ended { return "Session ended" + (exitCode.map { " · exit \($0)" } ?? "") }
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
                MainActor.assumeIsolated { session?.processEnded(exitCode) }
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
                    Text(session.attached ? "session reserved" : (session.attachError == nil ? "attaching…" : "not attached"))
                        .foregroundStyle(session.attached ? Color.doneGreen : Color.failedRed)
                }
                Spacer()
                if session.ended {
                    Button("Close") { model.removeSession(session) }
                } else {
                    Button("End session") { session.terminate() }
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
