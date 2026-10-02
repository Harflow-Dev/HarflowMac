import Foundation
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import SwiftEnvironment

// MARK: - MCPAllowlistUseCase

@Mockable
@MainActor
protocol MCPAllowlistUseCase {
    func request(backend: String, allow: String?, remove: String?) async throws -> [String: JSONValue]
}

// MARK: - MCPAllowlistRepository

@MainActor
final class MCPAllowlistRepository: MCPAllowlistUseCase {
    @GlobalEnvironment(\.toolEnvironmentRepository) private var environment

    func request(backend: String, allow: String?, remove: String?) async throws -> [String: JSONValue] {
        let client = try environment.ctl().get()
        return try await client.mcpAllowlist(backend: backend, allow: allow, remove: remove).get()
    }
}

// MARK: - MCPAllowlistVM

@Observable
@MainActor
final class MCPAllowlistVM: MCPAllowlistViewModel {
    let backend: String
    let title: String
    var entry = ""
    private(set) var entries: [String] = []
    private(set) var configPath = ""
    private(set) var detail = ""
    private(set) var supported = false
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let useCase: any MCPAllowlistUseCase

    init(backend: String, title: String, useCase: any MCPAllowlistUseCase) {
        self.backend = backend
        self.title = title
        self.useCase = useCase
    }

    static func backend(for key: String) -> String {
        key == "claude-code" ? "claude" : key
    }

    static func validEntry(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty }
            && !value.contains(where: \.isWhitespace)
    }

    var entryPlaceholder: String { backend == "vibe" ? "server/tool" : "server/tool or server/*" }
    var entryHelp: String {
        backend == "vibe" ? "Vibe supports exact tool names only; server wildcards are unavailable."
            : "Use server/* to approve every tool on one server."
    }

    var canAdd: Bool {
        supported && !isBusy && Self.validEntry(entry.trimmingCharacters(in: .whitespacesAndNewlines))
            && (backend != "vibe" || !entry.contains("*"))
    }

    func load() async { await request() }

    func confirmAdd() {
        guard canAdd else { return }
        let value = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        publishDialog("Allow \(value) globally?", description: "This lets \(title) call this MCP tool across projects and future tasks. "
                + (backend == "vibe" ? "This approves only the named tool. " : "A tool name of * allows every tool on that server. ")
                + "Other harness policies still apply.") {
            AlertAction(title: "Allow globally") { [weak self] in
                Task { await self?.request(allow: value) }
            }
        }
    }

    func confirmRemove(_ value: String) {
        guard supported, !isBusy, entries.contains(value) else { return }
        publishDialog("Remove global approval for \(value)?", description: "This removes the explicit approval from \(title)'s global configuration. "
                + "Other permission rules remain unchanged.") {
            AlertAction(title: "Remove approval") { [weak self] in
                Task { await self?.request(remove: value) }
            }
        }
    }

    private func request(allow: String? = nil, remove: String? = nil) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            let result = try await useCase.request(backend: backend, allow: allow, remove: remove)
            supported = result["supported"]?.boolValue == true
            entries = Array(Set(result["entries"]?.arrayValue?.compactMap(\.stringValue) ?? [])).sorted()
            configPath = result["config_path"]?.stringValue ?? ""
            detail = result["detail"]?.stringValue ?? ""
            errorMessage = nil
            if allow != nil { entry = "" }
        } catch {
            errorMessage = (error as? ToolError)?.message ?? error.localizedDescription
        }
    }
}
