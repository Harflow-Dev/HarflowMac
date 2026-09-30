import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - ToolEnvironmentRepositoryImpl

/// Ports `AppModel.discoverEnvironment`/`environment`/`ctl`/`setup` (`AppModel.swift:64-96`, = F4-02,
/// F4-03, F4-04), reworked so discovery publishes one coherent `DiscoveryResult` (R2-4) instead of
/// two independently-written fields. `ProcessRunning` and the base environment/home are injected so
/// tests never spawn a real login shell or `uv`.
public final class ToolEnvironmentRepositoryImpl: ToolEnvironmentRepository, @unchecked Sendable {

    public let home: String
    private let baseEnvironment: [String: String]
    private let runner: ProcessRunning
    private let settings: any SettingsRepository
    private let isExecutable: @Sendable (String) -> Bool

    @Subjected private var discoveryValue: DiscoveryResult
    private let discoveryCoordinator = DiscoveryCoordinator()

    public init(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runner: ProcessRunning = ProcessRunner(),
        settings: any SettingsRepository,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.runner = runner
        self.settings = settings
        self.isExecutable = isExecutable
        _discoveryValue = Subjected(wrappedValue: DiscoveryResult(loginPath: nil, uv: nil))
    }

    public var tasksDirectory: String { TaskTitle.tasksDirectory(home: home) }

    /// Re-reads the Settings override live on every access — this is the "changing toolDirectory
    /// triggers a refresh" seam (F4-05): nothing here is cached across a Settings change.
    public var locator: ToolLocator {
        let override = settings.toolDirectory
        return ToolLocator(
            overrideDirectory: override.isEmpty ? nil : override, home: home,
            uvToolBin: discoveryValue.uv?.binDirectory, isExecutable: isExecutable
        )
    }

    public var discovery: DiscoveryResult { discoveryValue }
    public func discoveryPublisher() -> AnyPublisher<DiscoveryResult, Never> { $discoveryValue.eraseToAnyPublisher() }

    public func discoverEnvironment() async -> DiscoveryResult {
        guard let waited = await discoveryCoordinator.waitOrClaim() else {
            return await runDiscoveryLoop()
        }
        return waited
    }

    /// Runs the probe loop to settling: this call claimed the run (nothing was in flight), so it
    /// keeps going for as long as later callers keep arming another pass, returning its own first
    /// pass's result (a later-arriving caller gets its own answer via the coordinator's waiters).
    private func runDiscoveryLoop() async -> DiscoveryResult {
        var firstResult: DiscoveryResult?
        repeat {
            let owed = await discoveryCoordinator.beginPass()
            let result = await probeOnce()
            if firstResult == nil { firstResult = result }
            let continueLoop = await discoveryCoordinator.endPass(owed: owed, result: result)
            if !continueLoop { break }
        } while true
        return firstResult ?? DiscoveryResult(loginPath: nil, uv: nil)
    }

    /// Asks an interactive login zsh — the shell Terminal gives you — for its PATH.
    static let interactivePathArgv = ["/bin/zsh", "-i", "-l", "-c", "printf %s \"$PATH\""]

    /// `primary`'s directories in order, then any of `extra`'s it lacks; `nil` only when both are.
    static func mergedPath(_ primary: String?, _ extra: String?) -> String? {
        let first = primary?.split(separator: ":").map(String.init) ?? []
        let second = extra?.split(separator: ":").map(String.init) ?? []
        var seen: Set<String> = []
        let merged = (first + second).filter { !$0.isEmpty && seen.insert($0).inserted }
        return merged.isEmpty ? nil : merged.joined(separator: ":")
    }

    /// F4-02/F4-03 combined into one coherent probe: the login-PATH probe (cwd = home, 8 s timeout,
    /// no tool-directory override), then the first `uv` candidate whose `uv tool dir --bin` exits 0.
    /// Timed-out probes are ignored; a run where no candidate succeeds publishes `uv: nil` — this
    /// unconditional overwrite (rather than a per-field conditional write) is what clears a stale
    /// resolution instead of leaving an old value behind.
    private func probeOnce() async -> DiscoveryResult {
        var loginPath: String?
        if case .success(let output) = await runner.run(
            executable: LaunchEnvironment.loginPathArgv[0],
            arguments: Array(LaunchEnvironment.loginPathArgv.dropFirst()),
            environment: LaunchEnvironment.build(base: baseEnvironment, loginPath: nil, toolDirectory: nil),
            currentDirectory: home,
            timeout: 8
        ), !output.timedOut {
            loginPath = LaunchEnvironment.parseLoginPath(output.stdout)
        }
        // A login shell reads ~/.zprofile but not ~/.zshrc, where tools like nvm (codex) and
        // opencode commonly add themselves — so the Settings harness list said "not on PATH" for
        // CLIs a Terminal finds. An interactive login shell's PATH fills those in; the same parser
        // keeps only a PATH-shaped last line, and the same timeout bounds a slow or chatty .zshrc.
        if case .success(let output) = await runner.run(
            executable: Self.interactivePathArgv[0],
            arguments: Array(Self.interactivePathArgv.dropFirst()),
            environment: LaunchEnvironment.build(base: baseEnvironment, loginPath: nil, toolDirectory: nil),
            currentDirectory: home,
            timeout: 8
        ), !output.timedOut {
            loginPath = Self.mergedPath(loginPath, LaunchEnvironment.parseLoginPath(output.stdout))
        }

        var uv: UvResolution?
        for candidate in uvCandidates(loginPath: loginPath) where isExecutable(candidate) {
            if case .success(let output) = await runner.run(
                executable: candidate, arguments: ["tool", "dir", "--bin"],
                environment: LaunchEnvironment.build(base: baseEnvironment, loginPath: loginPath, toolDirectory: nil),
                currentDirectory: nil, timeout: 8
            ), !output.timedOut, output.exitCode == 0 {
                // `uv`'s stdout could in principle be non-UTF8; a failable conversion here must not
                // crash the app, so the never-failing initializer is intentional.
                // swiftlint:disable:next optional_data_string_conversion
                let binDirectory = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                uv = UvResolution(executable: candidate, binDirectory: binDirectory)
                break
            }
        }

        let result = DiscoveryResult(loginPath: loginPath, uv: uv)
        discoveryValue = result
        return result
    }

    /// The fixed `uv` candidates first, then each executable `uv` found on the login PATH's own
    /// directories, deduplicated by normalized path so the same real binary is never probed twice.
    private func uvCandidates(loginPath: String?) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        func add(_ path: String) {
            guard seen.insert(normalize(path)).inserted else { return }
            result.append(path)
        }
        for fixed in ToolLocator.uvCandidates(home: home) { add(fixed) }
        if let loginPath {
            for dir in loginPath.split(separator: ":").map(String.init) where !dir.isEmpty {
                add((dir as NSString).appendingPathComponent("uv"))
            }
        }
        return result
    }

    private func normalize(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }

    public func environment(toolDirectory: String?) -> [String: String] {
        LaunchEnvironment.build(base: baseEnvironment, loginPath: discoveryValue.loginPath, toolDirectory: toolDirectory)
    }

    /// F4-04: the located binary's own folder goes on the environment's `PATH`.
    public func ctl() -> Result<CtlClient, ToolError> {
        locator.locate("polybridge-ctl").map { path in
            CtlClient(executable: path, environment: environment(toolDirectory: (path as NSString).deletingLastPathComponent))
        }
    }

    public func setup() -> Result<SetupClient, ToolError> {
        locator.locate("polybridge-setup").map { path in
            SetupClient(executable: path, environment: environment(toolDirectory: (path as NSString).deletingLastPathComponent))
        }
    }
}

// MARK: - DiscoveryCoordinator

/// Coalesces `discoverEnvironment()` the same way `TaskListRepositoryImpl.RefreshCoordinator`
/// coalesces `refresh()`, extended to hand each caller back a real result: a waiter that registers
/// while a pass is running is owed the result of the first pass that **starts after** its own
/// registration, never the one already in flight and never "whichever pass happens to settle the
/// whole chain" — see `beginPass()`/`endPass(owed:result:)`.
private actor DiscoveryCoordinator {
    private var running = false
    private var pendingWaiters: [CheckedContinuation<DiscoveryResult, Never>] = []

    /// One atomic decision: `nil` means nothing was running, so the caller must run the loop itself
    /// (and is now the one holding `running`); otherwise the caller is registered as a waiter and
    /// this suspends until a qualifying pass resolves it. Atomic because both the check and the
    /// registration happen in this one actor call — no pass can complete in the gap between them.
    func waitOrClaim() async -> DiscoveryResult? {
        if running {
            return await withCheckedContinuation { pendingWaiters.append($0) }
        }
        running = true
        return nil
    }

    /// One iteration boundary: everyone registered *before* this pass starts is now owed its
    /// result. Anyone registering *during* the pass that follows lands in a fresh batch instead.
    func beginPass() -> [CheckedContinuation<DiscoveryResult, Never>] {
        let owed = pendingWaiters
        pendingWaiters = []
        return owed
    }

    /// Resolves everyone this pass owed, then reports whether another pass is needed (someone
    /// registered while this one was running).
    func endPass(owed: [CheckedContinuation<DiscoveryResult, Never>], result: DiscoveryResult) -> Bool {
        for continuation in owed { continuation.resume(returning: result) }
        if pendingWaiters.isEmpty {
            running = false
            return false
        }
        return true
    }
}
