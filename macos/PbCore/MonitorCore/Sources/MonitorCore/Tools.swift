import Foundation

/// Where the app looks for `polybridge-ctl` and `polybridge-setup`, in order: a folder the user set
/// in Settings, `uv tool dir --bin`, then the usual install locations. The first folder holding the
/// binary wins, per binary — so a stale copy further down the list is never preferred.
public struct ToolLocator: Sendable {
    public var overrideDirectory: String?
    public var home: String
    /// Output of `uv tool dir --bin`, if uv answered.
    public var uvToolBin: String?
    public var isExecutable: @Sendable (String) -> Bool

    public init(
        overrideDirectory: String?,
        home: String,
        uvToolBin: String?,
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.overrideDirectory = overrideDirectory
        self.home = home
        self.uvToolBin = uvToolBin
        self.isExecutable = isExecutable
    }

    public var searchDirectories: [String] {
        var dirs: [String] = []
        for candidate in [
            overrideDirectory?.trimmingCharacters(in: .whitespacesAndNewlines),
            uvToolBin?.trimmingCharacters(in: .whitespacesAndNewlines),
            (home as NSString).appendingPathComponent(".local/bin"),
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ] {
            guard let dir = candidate, !dir.isEmpty else { continue }
            let expanded = (dir as NSString).expandingTildeInPath
            if !dirs.contains(expanded) { dirs.append(expanded) }
        }
        return dirs
    }

    public func locate(_ tool: String) -> Result<String, ToolError> {
        let dirs = searchDirectories
        for dir in dirs {
            let path = (dir as NSString).appendingPathComponent(tool)
            if isExecutable(path) { return .success(path) }
        }
        return .failure(.notFound(tool: tool, searched: dirs))
    }

    /// Where uv itself might live when the app has no useful PATH.
    public static func uvCandidates(home: String) -> [String] {
        [
            (home as NSString).appendingPathComponent(".local/bin/uv"),
            (home as NSString).appendingPathComponent(".cargo/bin/uv"),
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
    }
}

/// The environment for every process the app launches.
///
/// - every `PB_*` variable is dropped: the app is a person's tool, and a stray `PB_TASK_ID` would
///   make polybridge treat it as an agent (takeover refuses those outright);
/// - `PB_OPEN_MONITOR=0`, so nothing the app starts re-opens the app;
/// - `PATH` is the login shell's, with the tools folder first — a LaunchServices PATH finds neither
///   polybridge nor the agent CLIs that `takeover` and `run` need.
public enum LaunchEnvironment {
    public static let fallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func build(
        base: [String: String],
        loginPath: String?,
        toolDirectory: String?
    ) -> [String: String] {
        var env = base.filter { !$0.key.hasPrefix("PB_") }
        var path: [String] = []
        if let toolDirectory, !toolDirectory.isEmpty { path.append(toolDirectory) }
        let rest = (loginPath?.isEmpty == false ? loginPath! : (base["PATH"] ?? fallbackPath))
        for part in rest.split(separator: ":").map(String.init) where !part.isEmpty && !path.contains(part) {
            path.append(part)
        }
        env["PATH"] = path.joined(separator: ":")
        env["PB_OPEN_MONITOR"] = "0"
        return env
    }

    public static func asList(_ env: [String: String]) -> [String] {
        env.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
    }

    /// The argv that prints the login shell's PATH. Fixed text; nothing is interpolated.
    public static let loginPathArgv = ["/bin/zsh", "-l", "-c", "printf %s \"$PATH\""]
}

public struct ProcessOutput: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: Data
    public var stderr: String
    public var timedOut: Bool

    public init(exitCode: Int32, stdout: Data, stderr: String, timedOut: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
    }
}

/// Runs a process to completion with its stdin closed. Argv is an array end to end; nothing is
/// ever passed through a shell.
public protocol ProcessRunning: Sendable {
    func run(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError>
}

public struct ProcessRunner: ProcessRunning {
    public init() {}

    public func run(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: Self.runBlocking(executable: executable, arguments: arguments, environment: environment, currentDirectory: currentDirectory, timeout: timeout))
            }
        }
    }

    /// Signal the child only while it is provably still the process this call started: running
    /// per Foundation (not yet reaped), and — when its identity was captured — the same pid and
    /// start time in the process table right now. Returns whether a signal was sent.
    @discardableResult
    static func signalIfStillOurs(_ process: Process, _ identity: ProcessIdentity?, _ sig: Int32, table: ProcessTableReading = ProcessTable.system) -> Bool {
        guard process.isRunning else { return false }
        let pid = process.processIdentifier
        if let identity {
            guard identity.pid == pid, ProcessTable.liveness(identity, in: table) == .live else { return false }
        }
        return kill(pid, sig) == 0
    }

    public static func runBlocking(executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double) -> Result<ProcessOutput, ToolError> {
        let tool = (executable as NSString).lastPathComponent
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory) }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Both pipes are drained concurrently: an unread pipe that fills blocks the child. Each on a
        // thread of its own, not a GCD global-queue block: with the global queue's threads busy (a
        // loaded 3-core CI runner running suites in parallel), a queued reader could start too late
        // for the bounded drain below and the output was silently lost.
        let lock = NSLock()
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        group.enter()
        Thread {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
            group.leave()
        }.start()
        Thread {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
            group.leave()
        }.start()

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            try? outPipe.fileHandleForWriting.close()
            try? errPipe.fileHandleForWriting.close()
            return .failure(.launchFailed(tool: tool, detail: error.localizedDescription))
        }
        // The parent's copies of the write ends, so EOF arrives when the child exits.
        try? outPipe.fileHandleForWriting.close()
        try? errPipe.fileHandleForWriting.close()
        // (pid, start time) right after launch: Foundation reaps the child on its own queue, so by
        // the time a timeout fires the pid may already be free — and reused.
        let child = ProcessTable.lookup(process.processIdentifier)?.identity

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            Self.signalIfStillOurs(process, child, SIGTERM)
            if exited.wait(timeout: .now() + 3) == .timedOut {
                Self.signalIfStillOurs(process, child, SIGKILL)
                _ = exited.wait(timeout: .now() + 10)
            }
        }
        // A grandchild holding a pipe open must not hang the app: bounded drain.
        _ = group.wait(timeout: .now() + 2)
        lock.lock()
        let out = outData
        let err = String(decoding: errData, as: UTF8.self)
        lock.unlock()
        return .success(ProcessOutput(exitCode: Self.exitStatus(of: process), stdout: out, stderr: err, timedOut: timedOut))
    }

    /// `terminationStatus`, or -1 while the child is still running. A timed-out child can outlive
    /// every wait (its identity check undecidable, so neither signal is sent), and Foundation raises
    /// if the status is read before the process has exited.
    static func exitStatus(of process: Process) -> Int32 {
        process.isRunning ? -1 : process.terminationStatus
    }
}
