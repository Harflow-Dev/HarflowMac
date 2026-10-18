import Foundation
import MonitorCore

// MARK: - ToolPresence

/// Whether a tool binary was found at all — deliberately lower-level than SettingsFeature's
/// `ToolResolution`, which also carries *why* a path was chosen. This only needs "found here" or
/// "not found" to feed the install classifier.
public enum ToolPresence: Equatable, Sendable {
    case found(path: String)
    case notFound
}

// MARK: - InstallNeed

/// What the install banner should show for a `ToolError`, derived from it plus whether
/// `polybridge-ctl`/`polybridge-setup` are known to exist anywhere at all.
public enum InstallNeed: Equatable, Sendable {
    /// Neither `polybridge-ctl` nor `polybridge-setup` was found: "polybridge isn't installed."
    case missing
    /// One of the two is missing, or a command it used to support is now unrecognized:
    /// "polybridge is incomplete or out of date."
    case incomplete
}

// MARK: - InstallCommands

/// Pure constants, argv builders, and the install classifier — nothing here runs a process.
/// `InstallRepositoryImpl` is what actually spawns curl/sh/git/uv/pgrep using these.
public enum InstallCommands {

    // MARK: Source

    /// The only install source (Nayanda's decision): GitHub, unpinned for now. One constant, so
    /// pinning later is a one-line change.
    public static let source = "git+https://github.com/hainayanda/Polybridge.git"

    /// Run with the absolute `uv` path located for this operation.
    public static let polybridgeArguments = ["tool", "install", "--force", "--no-cache", source]

    // MARK: Fixed executables

    public static let curlExecutable = "/usr/bin/curl"
    public static let shExecutable = "/bin/sh"
    public static let xcodeSelectExecutable = "/usr/bin/xcode-select"
    public static let pgrepExecutable = "/usr/bin/pgrep"

    /// The Command Line Tools' `git` stub: needs `xcode-select -p` to succeed first, or invoking it
    /// pops the CLT installer dialog instead of running git.
    public static let gitStubPath = "/usr/bin/git"

    // MARK: uv bootstrap

    public static let uvInstallScriptURL = "https://astral.sh/uv/install.sh"

    /// `curl -fsSL --max-time 120 -o <destination> <install script URL>`.
    public static func uvDownloadArguments(destination: String) -> [String] {
        ["-fsSL", "--max-time", "120", "-o", destination, uvInstallScriptURL]
    }

    /// `UV_NO_MODIFY_PATH=1` so the downloaded installer never touches the user's shell rc files —
    /// the app's own login-PATH probe is the only thing that needs to see `uv`, and it re-probes
    /// after this stage runs.
    public static func uvNoModifyPathEnvironment(base: [String: String]) -> [String: String] {
        var env = base
        env["UV_NO_MODIFY_PATH"] = "1"
        return env
    }

    // MARK: git check

    public static let xcodeSelectArguments = ["-p"]
    public static let gitVersionArguments = ["--version"]

    /// The first `git` found by walking the install environment's own `PATH`, in the same order
    /// `uv` itself would search it — answering "which `git` would `uv` actually invoke."
    public static func firstGit(onPath environment: [String: String], isExecutable: (String) -> Bool) -> String? {
        guard let path = environment["PATH"] else { return nil }
        for dir in path.split(separator: ":").map(String.init) where !dir.isEmpty {
            let candidate = (dir as NSString).appendingPathComponent("git")
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }

    // MARK: Running-installer probe

    /// Advisory only (`InstallRepository.installAnyway()`): a match blocks the button; a clean
    /// result never proves every descendant of a previous install (the uv bootstrap's own shell or
    /// curl, or `uv tool install`'s own build step) has actually finished.
    public static func runningInstallerProbeArguments() -> [String] {
        ["-f", "tool install --force --no-cache git\\+https://github.com/hainayanda/Polybridge"]
    }

    // MARK: Classifier

    /// Only fires for a `.notFound`/`.unsupportedCommand` whose `tool` is exactly
    /// `"polybridge-ctl"` or `"polybridge-setup"` — every other `ToolError` keeps its existing
    /// message (`nil` here). Both missing is `.missing`; one missing, or an unsupported command, is
    /// `.incomplete`.
    public static func installNeed(for error: ToolError, ctl: ToolPresence, setup: ToolPresence) -> InstallNeed? {
        let tool: String
        let isUnsupportedCommand: Bool
        switch error {
        case .notFound(let value, _):
            tool = value
            isUnsupportedCommand = false
        case .unsupportedCommand(let value, _, _):
            tool = value
            isUnsupportedCommand = true
        default:
            return nil
        }
        guard tool == "polybridge-ctl" || tool == "polybridge-setup" else { return nil }

        let ctlMissing = isMissing(ctl)
        let setupMissing = isMissing(setup)
        if ctlMissing, setupMissing { return .missing }
        if ctlMissing || setupMissing || isUnsupportedCommand { return .incomplete }
        return nil
    }

    private static func isMissing(_ presence: ToolPresence) -> Bool {
        if case .notFound = presence { return true }
        return false
    }
}
