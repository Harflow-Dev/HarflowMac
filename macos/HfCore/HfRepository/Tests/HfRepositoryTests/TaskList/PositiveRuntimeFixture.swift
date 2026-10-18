import Foundation
import MonitorCore

/// Adds only the explicit compatibility probe to a positive operation fixture.
/// Operation responses and their counters remain owned by the supplied runner.
final class PositiveCtlRunner: ProcessRunning, @unchecked Sendable {
    private let delegate: StubProcessRunner

    init(_ delegate: StubProcessRunner) { self.delegate = delegate }

    func run(executable: String, arguments: [String], environment: [String: String],
             currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        if arguments == ["version-info", "--json"] {
            let root = (environment["HOME"] ?? NSHomeDirectory()) + "/.harflow"
            let json = "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                "\"product_version\":\"1.0.0\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}}," +
                "\"capabilities\":[\"ctl.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
            return .success(stdout(json))
        }
        return await delegate.run(executable: executable, arguments: arguments, environment: environment,
                                  currentDirectory: currentDirectory, timeout: timeout)
    }
}
