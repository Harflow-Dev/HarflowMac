import Foundation

// MARK: - LaunchEnvironment harness PATH discovery

public extension LaunchEnvironment {
    /// Interactive login shell supplements tools initialized only by the user's zshrc.
    static let interactivePathArgv = ["/bin/zsh", "-i", "-l", "-c", "printf %s \"$PATH\""]

    /// Keeps login directories first, adding only distinct interactive-shell directories.
    static func mergedPath(_ primary: String?, _ extra: String?) -> String? {
        let first = primary?.split(separator: ":").map(String.init) ?? []
        let second = extra?.split(separator: ":").map(String.init) ?? []
        var seen: Set<String> = []
        let merged = (first + second).filter { !$0.isEmpty && seen.insert($0).inserted }
        return merged.isEmpty ? nil : merged.joined(separator: ":")
    }

    /// Runs bounded fixed shell probes without resolving or adopting any engine executable.
    /// Invalid or timed-out output is ignored; callers retain their ordinary base-PATH fallback.
    static func discoverHarnessPath(home: String, environment: [String: String], runner: any ProcessRunning) async -> String? {
        var path: String?
        if case .success(let output) = await runner.run(
            executable: loginPathArgv[0], arguments: Array(loginPathArgv.dropFirst()),
            environment: environment, currentDirectory: home, timeout: 8
        ), !output.timedOut {
            path = parseLoginPath(output.stdout)
        }
        if case .success(let output) = await runner.run(
            executable: interactivePathArgv[0], arguments: Array(interactivePathArgv.dropFirst()),
            environment: environment, currentDirectory: home, timeout: 8
        ), !output.timedOut {
            path = mergedPath(path, parseLoginPath(output.stdout))
        }
        return path
    }
}
