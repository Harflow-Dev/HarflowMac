import Combine
import Foundation
import MonitorCore
import PbRepository
import PbUtilities

// MARK: - TerminalSessionRegistryImpl

@MainActor
public final class TerminalSessionRegistryImpl: TerminalSessionRegistry {

    @Subjected private var sessionsValue: [TerminalSession] = []
    private let endedSubject = PassthroughSubject<TerminalSession, Never>()

    public init() {}

    public var sessions: [TerminalSession] { sessionsValue }
    public func sessionsPublisher() -> AnyPublisher<[TerminalSession], Never> { $sessionsValue.eraseToAnyPublisher() }

    public var interactiveSessions: [TerminalSession] {
        sessionsValue.filter {
            if case .interactive = $0.kind { return !$0.ended }
            return false
        }
    }

    public func session(forTask taskID: String) -> TerminalSession? {
        sessionsValue.last {
            if case .takeover(let id) = $0.kind { return id == taskID }
            return false
        }
    }

    public func add(_ session: TerminalSession) {
        let previousOnEnded = session.onEnded
        session.onEnded = { [weak self, weak session] in
            previousOnEnded?()
            guard let self, let session else { return }
            endedSubject.send(session)
        }
        sessionsValue.append(session)
    }

    public func remove(_ session: TerminalSession) {
        session.terminate()
        sessionsValue.removeAll { $0 === session }
    }

    public func endedSessionsPublisher() -> AnyPublisher<TerminalSession, Never> {
        endedSubject.eraseToAnyPublisher()
    }

    @discardableResult
    public func startInteractive(backend: String, repo: String, environment: [String: String]) -> Result<TerminalSession, StartInteractiveError> {
        do {
            let command = try InteractiveSession.command(backend: backend, repo: repo, environment: environment)
            let session = TerminalSession(kind: .interactive, title: "\(backend) · \(RepoPathFormat.repo(repo))", backend: backend, command: command)
            add(session)
            session.start()
            return .success(session)
        } catch {
            return .failure(StartInteractiveError(message: "Could not start \(backend): \(error)"))
        }
    }
}
