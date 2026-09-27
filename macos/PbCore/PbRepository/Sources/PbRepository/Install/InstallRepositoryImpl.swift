import Combine
import Foundation
import MonitorCore
import PbUtilities

// MARK: - InstallRepositoryImpl

/// Drives the guarded install pipeline (settled plan, section 3): git → uv → polybridge → validate,
/// entered through `install()`/`installUvThenPolybridge()`/`retry()`/`checkAgain()`/`installAnyway()`,
/// each a no-op unless `state` currently allows it. `operationLock` guards every state-machine
/// transition (the "am I allowed to start" check and the state write are atomic together); once a
/// pipeline is running, nothing else can be, so the stage functions below never need it themselves.
public final class InstallRepositoryImpl: InstallRepository, @unchecked Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let taskListRepository: any TaskListRepository
    private let settings: any SettingsRepository
    private let runner: ProcessRunning
    private let isExecutable: @Sendable (String) -> Bool
    private let fileSize: @Sendable (String) -> Int
    private let makeTemporaryFile: @Sendable () -> String

    @Subjected private var stateValue: InstallState = .idle
    @Subjected private var lastCheckMessageValue: String?
    @Subjected private var installAnywayBlockedMessageValue: String?

    private let operationLock = NSLock()
    /// The `uv` this operation is using, captured once at the operation's start (or after a
    /// successful uv stage) and used through validation — never re-read from live discovery mid-run.
    private var capturedUv: UvResolution?
    /// The launch environment this operation captured alongside `capturedUv` — so a discovery that
    /// publishes mid-run (the startup one finishing late) can't change what later stages run with.
    private var capturedEnvironment: [String: String]?

    public init(
        toolEnvironment: any ToolEnvironmentRepository,
        taskListRepository: any TaskListRepository,
        settings: any SettingsRepository,
        runner: ProcessRunning = ProcessRunner(),
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
        fileSize: @escaping @Sendable (String) -> Int = { path in
            (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        },
        makeTemporaryFile: @escaping @Sendable () -> String = {
            FileManager.default.temporaryDirectory.appendingPathComponent("polybridge-uv-install-\(UUID().uuidString).sh").path
        }
    ) {
        self.toolEnvironment = toolEnvironment
        self.taskListRepository = taskListRepository
        self.settings = settings
        self.runner = runner
        self.isExecutable = isExecutable
        self.fileSize = fileSize
        self.makeTemporaryFile = makeTemporaryFile
    }

    // MARK: Published state

    public var state: InstallState { stateValue }
    public func statePublisher() -> AnyPublisher<InstallState, Never> { $stateValue.eraseToAnyPublisher() }
    public var lastCheckMessage: String? { lastCheckMessageValue }
    public func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { $lastCheckMessageValue.eraseToAnyPublisher() }
    public var installAnywayBlockedMessage: String? { installAnywayBlockedMessageValue }
    public func installAnywayBlockedMessagePublisher() -> AnyPublisher<String?, Never> { $installAnywayBlockedMessageValue.eraseToAnyPublisher() }

    /// While `unresolved`, `installAnyway()` reinstalls into the captured destination, so that is the
    /// one the dialog must name; otherwise the next `install()` re-discovers, so the live one is.
    public func destination() -> String? {
        operationLock.lock()
        let captured: String? = if case .unresolved = stateValue { capturedUv?.binDirectory } else { nil }
        operationLock.unlock()
        return captured ?? toolEnvironment.discovery.uv?.binDirectory
    }

    // MARK: Entry points

    public func install() async {
        guard beginIfAllowed(Self.allowsInstall, entering: .running(.git)) else { return }
        await runFromGit()
    }

    public func installUvThenPolybridge() async {
        guard beginIfAllowed({ $0 == .needsUv }, entering: .running(.uv)) else { return }
        await runUvThenContinue()
    }

    public func retry() async {
        guard let stage = beginRetryIfAllowed() else { return }
        switch stage {
        case .git: await runFromGit()
        case .uv: await runUvThenContinue()
        case .polybridge: await runPolybridgeThenValidate()
        case .validate: await runValidate(originStageIfUnresolved: nil)
        }
    }

    public func checkAgain() async {
        guard let origin = beginCheckAgainIfAllowed() else { return }
        await runValidate(originStageIfUnresolved: origin)
    }

    @discardableResult
    public func installAnyway() async -> Bool {
        guard let stage = beginInstallAnywayIfAllowed() else { return false }
        guard !(await runningInstallerProbeMatches(environment: stageEnvironment(toolDirectory: capturedUv?.binDirectory))) else {
            installAnywayBlockedMessageValue = "An earlier install may still be finishing, so Install anyway is refused until it's confirmed stopped."
            setState(.unresolved(stage: stage))
            return false
        }
        installAnywayBlockedMessageValue = nil
        switch stage {
        case .uv: await runUvThenContinue()
        case .polybridge: await runPolybridgeThenValidate()
        case .git, .validate: break // git/validate never produce `unresolved`; unreachable in practice.
        }
        return true
    }

    public func reset() {
        operationLock.lock()
        defer { operationLock.unlock() }
        switch stateValue {
        case .failed, .installed:
            stateValue = .idle
            lastCheckMessageValue = nil
            installAnywayBlockedMessageValue = nil
            capturedUv = nil
            capturedEnvironment = nil
        case .idle, .needsGit, .needsUv, .running, .unresolved:
            break
        }
    }

    // MARK: Guarded transitions (synchronous — never called with an `await` in flight)

    private static func allowsInstall(_ state: InstallState) -> Bool {
        switch state {
        case .idle, .failed, .needsGit, .needsUv, .installed: true
        case .running, .unresolved: false
        }
    }

    private func beginIfAllowed(_ isAllowed: (InstallState) -> Bool, entering next: InstallState) -> Bool {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard isAllowed(stateValue) else { return false }
        stateValue = next
        return true
    }

    private func beginRetryIfAllowed() -> InstallStage? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard case .failed(let stage, _) = stateValue else { return nil }
        stateValue = .running(stage)
        return stage
    }

    /// `.some(.some(stage))` = allowed, resuming from `unresolved(stage)`; `.some(.none)` = allowed,
    /// resuming from `failed(.validate, _)` (no origin stage to fall back to); `.none` = not allowed.
    private func beginCheckAgainIfAllowed() -> InstallStage?? {
        operationLock.lock()
        defer { operationLock.unlock() }
        switch stateValue {
        case .unresolved(let stage):
            stateValue = .running(.validate)
            let origin: InstallStage? = stage
            return .some(origin)
        case .failed(.validate, _):
            stateValue = .running(.validate)
            let origin: InstallStage? = nil
            return .some(origin)
        default:
            return .none
        }
    }

    private func beginInstallAnywayIfAllowed() -> InstallStage? {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard case .unresolved(let stage) = stateValue else { return nil }
        stateValue = .running(stage)
        return stage
    }

    /// A plain assignment, but always called from inside an already-guarded pipeline (never
    /// competing with another entry point), so it needs no lock of its own.
    private func setState(_ next: InstallState) {
        stateValue = next
    }

    // MARK: Pipeline

    private func runFromGit() async {
        setState(.running(.git))
        // A known uv is the destination the confirmation dialog just named, so bind to that rather
        // than re-discovering; only look again when none is known yet. Either way uv comes first,
        // so the git check runs against the very PATH uv will be given.
        if toolEnvironment.discovery.uv == nil { _ = await toolEnvironment.discoverEnvironment() }
        captureLatestDiscovery()
        guard await runGitCheck(environment: stageEnvironment(toolDirectory: capturedUv?.binDirectory)) else {
            setState(.needsGit)
            return
        }
        if capturedUv != nil {
            await runPolybridgeThenValidate()
        } else {
            setState(.needsUv)
        }
    }

    private func runUvThenContinue() async {
        setState(.running(.uv))
        switch await runUvBootstrap(environment: stageEnvironment(toolDirectory: nil)) {
        case .success:
            // The one re-capture the plan allows: the uv stage's own re-discovery found the new uv.
            captureLatestDiscovery()
            guard capturedUv != nil else {
                setState(.failed(stage: .uv, message: "uv finished installing, but still couldn't be found."))
                return
            }
            // The new uv's folder now leads the PATH, which can change which git uv would run.
            guard await runGitCheck(environment: stageEnvironment(toolDirectory: capturedUv?.binDirectory)) else {
                setState(.needsGit)
                return
            }
            await runPolybridgeThenValidate()
        case .failure(let message):
            setState(.failed(stage: .uv, message: message))
        case .unresolved:
            setState(.unresolved(stage: .uv))
        }
    }

    private func runPolybridgeThenValidate() async {
        setState(.running(.polybridge))
        guard let uv = capturedUv else {
            setState(.failed(stage: .polybridge, message: "uv hasn't been located yet, so polybridge can't be installed."))
            return
        }
        switch await runPolybridgeInstall(uv: uv, environment: stageEnvironment(toolDirectory: uv.binDirectory)) {
        case .success:
            await runValidate(originStageIfUnresolved: nil)
        case .failure(let message):
            setState(.failed(stage: .polybridge, message: message))
        case .unresolved:
            setState(.unresolved(stage: .polybridge))
        }
    }

    /// `originStageIfUnresolved` is the stage the caller was `unresolved` at (from `checkAgain()`);
    /// `nil` means "a normal forward pass or a `.validate` retry" (a fresh failure here is
    /// `failed(.validate, …)`, never `unresolved`).
    private func runValidate(originStageIfUnresolved: InstallStage?) async {
        setState(.running(.validate))
        switch await validate() {
        case .success:
            lastCheckMessageValue = nil
            setState(.installed)
        case .failure(let message):
            lastCheckMessageValue = message
            if let originStage = originStageIfUnresolved {
                setState(.unresolved(stage: originStage))
            } else {
                setState(.failed(stage: .validate, message: message))
            }
        }
    }

    // MARK: git stage

    private func runGitCheck(environment: [String: String]) async -> Bool {
        guard let gitPath = InstallCommands.firstGit(onPath: environment, isExecutable: isExecutable) else { return false }
        if gitPath == InstallCommands.gitStubPath {
            guard case .success(let output) = await runner.run(
                executable: InstallCommands.xcodeSelectExecutable, arguments: InstallCommands.xcodeSelectArguments,
                environment: environment, currentDirectory: nil, timeout: 10
            ), output.exitCode == 0 else { return false }
        }
        guard case .success(let output) = await runner.run(
            executable: gitPath, arguments: InstallCommands.gitVersionArguments,
            environment: environment, currentDirectory: nil, timeout: 10
        ), output.exitCode == 0 else { return false }
        return true
    }

    // MARK: uv stage

    private enum StageOutcome<Success> {
        case success(Success)
        case failure(String)
        case unresolved
    }

    /// `Result<Void, String>` isn't expressible directly (`String` doesn't conform to `Error`), and
    /// validate has no `unresolved` outcome, so it gets its own two-case enum rather than reusing
    /// `StageOutcome`.
    private enum ValidationOutcome {
        case success
        case failure(String)
    }

    private func runUvBootstrap(environment: [String: String]) async -> StageOutcome<UvResolution> {
        let tmpFile = makeTemporaryFile()
        defer { try? FileManager.default.removeItem(atPath: tmpFile) }

        switch await runner.run(
            executable: InstallCommands.curlExecutable, arguments: InstallCommands.uvDownloadArguments(destination: tmpFile),
            environment: environment, currentDirectory: nil, timeout: 150
        ) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let output):
            if output.timedOut { return .unresolved }
            guard output.exitCode == 0, fileSize(tmpFile) > 0 else {
                return .failure("Downloading uv's installer failed." + stderrTail(output.stderr))
            }
        }

        switch await runner.run(
            executable: InstallCommands.shExecutable, arguments: [tmpFile],
            environment: InstallCommands.uvNoModifyPathEnvironment(base: environment), currentDirectory: nil, timeout: 300
        ) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let output):
            if output.timedOut { return .unresolved }
            guard output.exitCode == 0 else {
                return .failure("Installing uv failed." + stderrTail(output.stderr))
            }
        }

        let discovery = await toolEnvironment.discoverEnvironment()
        guard let uv = discovery.uv else {
            return .failure("uv finished installing, but still couldn't be found.")
        }
        return .success(uv)
    }

    // MARK: polybridge stage

    private func runPolybridgeInstall(uv: UvResolution, environment: [String: String]) async -> StageOutcome<Void> {
        switch await runner.run(
            executable: uv.executable, arguments: InstallCommands.polybridgeArguments,
            environment: environment, currentDirectory: toolEnvironment.home, timeout: 600
        ) {
        case .failure(let error):
            return .failure(error.message)
        case .success(let output):
            if output.timedOut { return .unresolved }
            guard output.exitCode == 0 else {
                return .failure("Installing polybridge failed." + stderrTail(output.stderr))
            }
            return .success(())
        }
    }

    // MARK: validate stage

    private func validate() async -> ValidationOutcome {
        if capturedUv == nil {
            // Reachable after a uv-stage timeout: nothing was captured, but uv (and polybridge) may
            // have finished since. Discovery is read-only, so a check may look.
            _ = await toolEnvironment.discoverEnvironment()
            captureLatestDiscovery()
        }
        guard let uv = capturedUv else {
            return .failure("uv hasn't been located yet, so there's no install destination to check.")
        }
        let destination = uv.binDirectory
        let environment = stageEnvironment(toolDirectory: destination)
        let ctlPath = (destination as NSString).appendingPathComponent("polybridge-ctl")
        let setupPath = (destination as NSString).appendingPathComponent("polybridge-setup")

        // 1. Destination check.
        guard isExecutable(ctlPath) else {
            return .failure("polybridge installed, but polybridge-ctl isn't in it. The version on GitHub may not include it yet.")
        }
        guard isExecutable(setupPath) else {
            return .failure("polybridge installed, but polybridge-setup isn't in it. The version on GitHub may not include it yet.")
        }

        // 2. Effective selection.
        if let message = shadowMessage(tool: "polybridge-ctl", destinationPath: ctlPath, destination: destination) {
            return .failure(message)
        }
        if let message = shadowMessage(tool: "polybridge-setup", destinationPath: setupPath, destination: destination) {
            return .failure(message)
        }

        // 3. Contracts.
        let ctlClient = CtlClient(executable: ctlPath, environment: environment, runner: runner)
        if case .failure(let error) = await ctlClient.list() { return .failure(error.message) }
        let setupClient = SetupClient(executable: setupPath, environment: environment, runner: runner)
        if case .failure(let error) = await setupClient.perform(.status) { return .failure(error.message) }

        // 4. Barrier.
        switch await taskListRepository.refreshAndWait() {
        case .success: return .success
        case .failure(let error): return .failure(error.message)
        }
    }

    private func shadowMessage(tool: String, destinationPath: String, destination: String) -> String? {
        guard case .success(let effectivePath) = toolEnvironment.locator.locate(tool) else {
            return "The new \(tool) in \(destination) isn't where the app looks for polybridge."
        }
        guard normalize(effectivePath) != normalize(destinationPath) else { return nil }
        let overrideDirectory = settings.toolDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveDirectory = (normalize(effectivePath) as NSString).deletingLastPathComponent
        if !overrideDirectory.isEmpty, effectiveDirectory == normalize((overrideDirectory as NSString).expandingTildeInPath) {
            return "Settings → General points polybridge at \(overrideDirectory), which hides the new install. Clear it to use the new one."
        }
        return "Another polybridge at \(effectivePath) is being used instead of the new install in \(destination)."
    }

    private func normalize(_ path: String) -> String {
        ((path as NSString).standardizingPath as NSString).resolvingSymlinksInPath
    }

    // MARK: Running-installer probe

    /// `true` = treat as a match (blocks `installAnyway()`): a clean "no match" is exit 1 only;
    /// exit 0, any other exit code, a timeout, or a launch failure all count as "might still be
    /// running" — the probe can only block, never approve.
    private func runningInstallerProbeMatches(environment: [String: String]) async -> Bool {
        switch await runner.run(
            executable: InstallCommands.pgrepExecutable, arguments: InstallCommands.runningInstallerProbeArguments(),
            environment: environment, currentDirectory: nil, timeout: 5
        ) {
        case .failure: return true
        case .success(let output):
            if output.timedOut { return true }
            return output.exitCode != 1
        }
    }

    // MARK: Shared

    /// Takes uv and the environment from the same, latest published discovery, so the two always
    /// describe one run — the result a waiter is handed can be older than what has since published.
    private func captureLatestDiscovery() {
        // The two reads lock independently, so re-read until no publish landed between them.
        var discovery = toolEnvironment.discovery
        var environment = toolEnvironment.environment()
        for _ in 0 ..< 5 {
            let after = toolEnvironment.discovery
            if after == discovery { break }
            discovery = after
            environment = toolEnvironment.environment()
        }
        capturedUv = discovery.uv
        capturedEnvironment = environment
    }

    /// The captured environment (captured now if this operation has none yet), with `toolDirectory`
    /// first on its `PATH`.
    private func stageEnvironment(toolDirectory: String?) -> [String: String] {
        let base = capturedEnvironment ?? toolEnvironment.environment()
        if capturedEnvironment == nil { capturedEnvironment = base }
        return LaunchEnvironment.build(base: base, loginPath: base["PATH"], toolDirectory: toolDirectory)
    }

    private func stderrTail(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !lines.isEmpty else { return "" }
        return " " + lines.suffix(5).joined(separator: " ")
    }
}
