import Foundation
import MonitorCore

// MARK: - ModelCatalogRepositoryImpl

/// Discovers model lists per backend. The process runner and file reader are injected so tests never
/// spawn `opencode` or read a real `~/.codex`.
public final class ModelCatalogRepositoryImpl: ModelCatalogRepository, Sendable {

    private let toolEnvironment: any ToolEnvironmentRepository
    private let runner: ProcessRunning
    private let readFile: @Sendable (String) -> Data?
    private let cache = ModelCache()

    /// How long `opencode models` may run before it is abandoned.
    static let opencodeTimeout: Double = 8

    /// How long `agy models` may run before it is abandoned.
    static let agyTimeout: Double = 8

    /// The aliases `claude --help` documents for `--model`.
    static let claudeAliases = ["fable", "opus", "sonnet"]

    public init(
        toolEnvironment: any ToolEnvironmentRepository,
        runner: ProcessRunning = ProcessRunner(),
        readFile: @escaping @Sendable (String) -> Data? = { FileManager.default.contents(atPath: $0) }
    ) {
        self.toolEnvironment = toolEnvironment
        self.runner = runner
        self.readFile = readFile
    }

    public func models(for backend: String) async -> [ModelOption] {
        await cache.models(for: backend) { [self] in await discover(backend) }
    }

    // MARK: Discovery

    private func discover(_ backend: String) async -> [ModelOption] {
        switch backend {
        case "opencode": await opencodeModels()
        case "antigravity": await agyModels()
        case "codex": codexModels()
        case "claude": Self.claudeAliases.map { ModelOption(value: $0, label: $0.capitalized) }
        default: []
        }
    }

    /// `agy models` prints `<id>\t<label>` per line, preceded by a `Fetching available models...`
    /// notice; the PATH is the discovered login+interactive one, which `env` uses to find the
    /// binary.
    private func agyModels() async -> [ModelOption] {
        let result = await runner.run(
            executable: "/usr/bin/env", arguments: ["agy", "models"],
            environment: toolEnvironment.environment(), currentDirectory: toolEnvironment.home,
            timeout: Self.agyTimeout
        )
        guard case .success(let output) = result, !output.timedOut, output.exitCode == 0 else { return [] }
        return Self.parseAgy(output.stdout)
    }

    /// One option per non-blank line that is not the fetching notice: the id up to the first tab,
    /// the label after it — the id itself when there is no tab or the label is blank.
    static func parseAgy(_ data: Data) -> [ModelOption] {
        (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "Fetching available models..." }
            .map { line in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let id = fields.first ?? ""
                let label = fields.count > 1 && !fields[1].isEmpty ? fields[1] : id
                return ModelOption(value: id, label: label)
            }
    }

    /// `opencode models` prints one model id per line; the PATH is the discovered login+interactive
    /// one, which `env` uses to find the binary.
    private func opencodeModels() async -> [ModelOption] {
        let result = await runner.run(
            executable: "/usr/bin/env", arguments: ["opencode", "models"],
            environment: toolEnvironment.environment(), currentDirectory: toolEnvironment.home,
            timeout: Self.opencodeTimeout
        )
        guard case .success(let output) = result, !output.timedOut, output.exitCode == 0 else { return [] }
        return Self.parseOpencode(output.stdout)
    }

    static func parseOpencode(_ data: Data) -> [ModelOption] {
        var seen = Set<String>()
        return (String(data: data, encoding: .utf8) ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
            .map { ModelOption(value: $0, label: $0) }
    }

    /// codex's private `models_cache.json`; `CODEX_HOME` wins over `~/.codex`.
    private func codexModels() -> [ModelOption] {
        let codexHome = toolEnvironment.environment()["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (toolEnvironment.home as NSString).appendingPathComponent(".codex")
        guard let data = readFile((codexHome as NSString).appendingPathComponent("models_cache.json")) else { return [] }
        return Self.parseCodexCache(data)
    }

    /// Only `visibility == "list"` models, ascending `priority` (missing priority sorts last, ties
    /// keep file order). The file is undocumented, so any deviation from the expected shape yields
    /// an empty list or skips the offending entry rather than throwing.
    static func parseCodexCache(_ data: Data) -> [ModelOption] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return [] }
        let listed: [(priority: Double, option: ModelOption)] = models.compactMap { entry in
            guard entry["visibility"] as? String == "list",
                  let slug = (entry["slug"] as? String)?.trimmingCharacters(in: .whitespaces), !slug.isEmpty else { return nil }
            let name = (entry["display_name"] as? String)?.trimmingCharacters(in: .whitespaces)
            let priority = (entry["priority"] as? NSNumber)?.doubleValue ?? .greatestFiniteMagnitude
            return (priority, ModelOption(value: slug, label: name?.isEmpty == false ? name! : slug))
        }
        return listed.enumerated()
            .sorted { ($0.element.priority, $0.offset) < ($1.element.priority, $1.offset) }
            .map(\.element.option)
    }
}

// MARK: - ModelCache

/// Per-backend cache that also coalesces concurrent requests for the same backend. Empty results are
/// dropped so the next request retries.
private actor ModelCache {
    private var tasks: [String: Task<[ModelOption], Never>] = [:]

    func models(for backend: String, discover: @escaping @Sendable () async -> [ModelOption]) async -> [ModelOption] {
        if let task = tasks[backend] { return await task.value }
        let task = Task { await discover() }
        tasks[backend] = task
        let result = await task.value
        if result.isEmpty { tasks[backend] = nil }
        return result
    }
}
