import Foundation
import MonitorCore
import PbUtilities

// MARK: - ToolEnvironmentRepositoryImpl

/// Ports `AppModel.discoverEnvironment`/`environment`/`ctl`/`setup` verbatim (`AppModel.swift:64-96`,
/// = F4-02, F4-03, F4-04). `ProcessRunning` and the base environment/home are injected so tests never
/// spawn a real login shell or `uv`.
public final class ToolEnvironmentRepositoryImpl: ToolEnvironmentRepository, @unchecked Sendable {

    public let home: String
    private let baseEnvironment: [String: String]
    private let runner: ProcessRunning
    private let settings: any SettingsRepository

    @Subjected private var loginPathValue: String?
    @Subjected private var uvToolBinValue: String?

    public init(
        home: String = ProcessInfo.processInfo.environment["HOME"] ?? NSHomeDirectory(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runner: ProcessRunning = ProcessRunner(),
        settings: any SettingsRepository
    ) {
        self.home = home
        self.baseEnvironment = baseEnvironment
        self.runner = runner
        self.settings = settings
        _loginPathValue = Subjected(wrappedValue: nil)
        _uvToolBinValue = Subjected(wrappedValue: nil)
    }

    public var tasksDirectory: String { TaskTitle.tasksDirectory(home: home) }

    /// Re-reads the Settings override live on every access — this is the "changing toolDirectory
    /// triggers a refresh" seam (F4-05): nothing here is cached across a Settings change.
    public var locator: ToolLocator {
        let override = settings.toolDirectory
        return ToolLocator(overrideDirectory: override.isEmpty ? nil : override, home: home, uvToolBin: uvToolBinValue)
    }

    public func discoverEnvironment() async {
        // F4-02: login-PATH probe, cwd = home, 8 s timeout, no tool-directory override.
        if case .success(let output) = await runner.run(
            executable: LaunchEnvironment.loginPathArgv[0],
            arguments: Array(LaunchEnvironment.loginPathArgv.dropFirst()),
            environment: LaunchEnvironment.build(base: baseEnvironment, loginPath: nil, toolDirectory: nil),
            currentDirectory: home,
            timeout: 8
        ) {
            loginPathValue = LaunchEnvironment.parseLoginPath(output.stdout)
        }
        // F4-03: the first uv candidate whose `uv tool dir --bin` exits 0 wins.
        for uvPath in ToolLocator.uvCandidates(home: home) where FileManager.default.isExecutableFile(atPath: uvPath) {
            if case .success(let output) = await runner.run(
                executable: uvPath, arguments: ["tool", "dir", "--bin"], environment: environment(toolDirectory: nil),
                currentDirectory: nil, timeout: 8
            ),
               output.exitCode == 0 {
                // `uv`'s stdout could in principle be non-UTF8; a failable conversion here must not
                // crash the app, so the never-failing initializer is intentional.
                // swiftlint:disable:next optional_data_string_conversion
                uvToolBinValue = String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
    }

    public func environment(toolDirectory: String?) -> [String: String] {
        LaunchEnvironment.build(base: baseEnvironment, loginPath: loginPathValue, toolDirectory: toolDirectory)
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
