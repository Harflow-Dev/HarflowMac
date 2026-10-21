import Darwin
import Foundation

// MARK: - ManagedRuntimeProcessRunner

/// Installer-only subprocess execution with bounded output, timeout, and cancellation cleanup.
public struct ManagedRuntimeProcessRunner: ProcessRunning {
    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init() {}

    public func run(executable: String, arguments: [String], environment: [String: String],
                    currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        let operation = ManagedRuntimeProcessOperation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: operation.run(executable: executable, arguments: arguments,
                                                               environment: environment, directory: currentDirectory, timeout: timeout))
                }
            }
        } onCancel: {
            operation.cancel()
        }
    }
}

// MARK: - ManagedRuntimeProcessOperation

private final class ManagedRuntimeProcessOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run(executable: String, arguments: [String], environment: [String: String],
             directory: String?, timeout: Double) -> Result<ProcessOutput, ToolError> {
        guard !isCancelled else { return .failure(.launchFailed(tool: executable, detail: "Preparation cancelled.")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory.map { URL(fileURLWithPath: $0) }
        process.standardInput = FileHandle.nullDevice
        let stdout = ManagedRuntimeProcessPipe()
        let stderr = ManagedRuntimeProcessPipe()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed(tool: executable, detail: error.localizedDescription))
        }
        let identity = ProcessTable.lookup(process.processIdentifier)?.identity
        stdout.start()
        stderr.start()
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while exited.wait(timeout: .now() + 0.1) == .timedOut {
            if isCancelled || Date() >= deadline {
                timedOut = !isCancelled
                ProcessRunner.signalIfStillOurs(process, identity, SIGTERM)
                if exited.wait(timeout: .now() + 3) == .timedOut {
                    ProcessRunner.signalIfStillOurs(process, identity, SIGKILL)
                    _ = exited.wait(timeout: .now() + 10)
                }
                break
            }
        }
        let output = stdout.finish()
        let errors = stderr.finish()
        return .success(ProcessOutput(exitCode: ProcessRunner.exitStatus(of: process), stdout: output,
                                      stderr: String(data: errors, encoding: .utf8) ?? "Invalid UTF-8 subprocess output.", timedOut: timedOut))
    }
}

// MARK: - ManagedRuntimeProcessPipe

private final class ManagedRuntimeProcessPipe: @unchecked Sendable {
    let pipe = Pipe()
    private let lock = NSLock()
    private let drained = DispatchSemaphore(value: 0)
    private var bytes = Data()

    func start() {
        try? pipe.fileHandleForWriting.close()
        Thread { [self] in
            while let chunk = try? pipe.fileHandleForReading.read(upToCount: 32768), !chunk.isEmpty {
                lock.lock()
                let available = max(0, (2 << 20) - bytes.count)
                bytes.append(chunk.prefix(available))
                lock.unlock()
            }
            drained.signal()
        }.start()
    }

    func finish() -> Data {
        _ = drained.wait(timeout: .now() + 2)
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }
}
