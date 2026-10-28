import Foundation
import HfRepository
import MonitorCore

/// Explicit test-only evidence; never a fallback in production composition.
final class QualificationFixture: QualificationRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private let gated: Bool
    private let error: ToolError?
    private let additionalBackend: String?
    private var checkCount = 0
    var checks: Int { lock.withLock { checkCount } }
    init(ready: Bool = true, gated: Bool = true, error: ToolError? = nil, additionalBackend: String? = nil) {
        self.ready = ready
        self.gated = gated
        self.error = error
        self.additionalBackend = additionalBackend
    }

    func setReady(_ ready: Bool) { lock.withLock { self.ready = ready } }
    func runtimeToken() throws -> QualificationRuntimeToken {
        if let error { throw error }
        return QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: [:]))
    }

    func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
        let id: String
        let backend: String
        var workflow = false
        switch request {
        case .task(let options):
            id = "task"
            backend = options.first(where: { $0.hasPrefix("--backend=") }).map { String($0.dropFirst("--backend=".count)) } ?? "fixture"
        case .workflow: id = "fixture/orchestrator/0"; backend = "fixture"; workflow = true
        case .harness(let name): id = "settings/" + name; backend = name
        }
        let ready = lock.withLock { self.ready }
        var rows = [row(id: id, backend: backend, ready: ready)]
        if workflow, let additionalBackend {
            rows.append(row(id: "fixture/node/work/0", backend: additionalBackend, ready: ready))
        }
        return BackendQualificationPlan(["qualification_version": .number(1), "discovery_only": .bool(true),
                                         "requirements": .array(rows)])!
    }

    private func row(id: String, backend: String, ready: Bool) -> JSONValue {
        if !gated {
            return .object(["id": .string(id), "backend": .string(backend), "required_features": .array([]), "features": .object([:])])
        }
        let identity: JSONValue = .object(["backend": .string(backend), "version": .string("fixture"),
            "executable": .string("/fixture/" + backend), "binary_sha256": .string(String(repeating: "a", count: 64)),
            "platform": .string("darwin-arm64")])
        return .object(["id": .string(id), "backend": .string(backend), "identity": identity,
            "required_features": .array([.string("write")]), "features": .object(["write": .object([
                "ok": .bool(ready), "source": .string(ready ? "seeded" : "failed"), "identity": identity])])])
    }

    func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
        lock.withLock { checkCount += 1 }
    }

    static func readySession() -> QualificationSession { QualificationSession(repository: QualificationFixture(gated: false)) }
}

final class CachedFailureQualificationFixture: QualificationRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var failNextRead = true
    private let base = QualificationFixture()
    var checks: Int { base.checks }
    func runtimeToken() throws -> QualificationRuntimeToken { try base.runtimeToken() }
    func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
        let fail = lock.withLock { let current = failNextRead; failNextRead = false; return current }
        if fail { throw ToolError.launchFailed(tool: "fixture", detail: "Fixture cached read failed") }
        return try await base.discover(request, runtime: runtime)
    }

    func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
        try await base.check(backend: backend, features: features, runtime: runtime)
    }
}

final class QualificationSessionQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [QualificationSession]
    init(_ sessions: [QualificationSession]) { self.sessions = sessions }
    func next() -> QualificationSession { lock.withLock { sessions.removeFirst() } }
}

actor QualificationCheckGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        entry?.resume(); entry = nil
        await withCheckedContinuation { release = $0 }
    }

    func waitForEntry() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }

    func open() { release?.resume(); release = nil }
}

final class SuspendedQualificationFixture: QualificationRepository, @unchecked Sendable {
    let base: QualificationFixture
    let gate: QualificationCheckGate
    init(base: QualificationFixture, gate: QualificationCheckGate) { self.base = base; self.gate = gate }
    func runtimeToken() throws -> QualificationRuntimeToken { try base.runtimeToken() }
    func discover(_ request: QualificationRequest, runtime: QualificationRuntimeToken) async throws -> BackendQualificationPlan {
        try await base.discover(request, runtime: runtime)
    }

    func check(backend: String, features: [String], runtime: QualificationRuntimeToken) async throws {
        await gate.wait()
        try await base.check(backend: backend, features: features, runtime: runtime)
    }
}
