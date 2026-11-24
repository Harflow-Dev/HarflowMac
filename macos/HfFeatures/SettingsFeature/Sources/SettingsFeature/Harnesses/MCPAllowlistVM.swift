import Foundation
import HfCommon
import HfRepository
import Mockable
import MonitorCore
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
    /// The refusal code of the last failed read or change, shown on a "Code" line under the message.
    private(set) var errorCode: String?
    /// The one-sentence missing-feature form, shown when the runtime has no `mcp-allowlist` command.
    private(set) var missingFeatureSentence: String?
    /// A read or a change has returned a document since the panel opened or the last failed read.
    private(set) var hasAnswer = false
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

    /// The runtime answered and this harness has no global approvals.
    var showsEmpty: Bool { hasAnswer && supported && entries.isEmpty }

    /// The entry field is usable once a read has succeeded for a harness whose approvals Harflow edits. It stays
    /// enabled while a request runs, so its focus survives a write.
    var fieldEnabled: Bool { hasAnswer && supported }

    /// Add, Remove and the other changes: the field's condition and nothing running.
    var actionsEnabled: Bool { fieldEnabled && !isBusy }

    var canAdd: Bool {
        hasAnswer && supported && !isBusy && Self.validEntry(entry.trimmingCharacters(in: .whitespacesAndNewlines))
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
        guard hasAnswer, supported, !isBusy, entries.contains(value) else { return }
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
            guard !Task.isCancelled else { return }
            apply(result)
            if allow != nil { entry = "" }
        } catch {
            guard !Task.isCancelled else { return }
            fail(error, isRead: allow == nil && remove == nil)
        }
    }

    private func apply(_ result: [String: JSONValue]) {
        update(\.supported, result["supported"]?.boolValue == true)
        update(\.entries, Array(Set(result["entries"]?.arrayValue?.compactMap(\.stringValue) ?? [])).sorted())
        update(\.configPath, result["config_path"]?.stringValue ?? "")
        update(\.detail, result["detail"]?.stringValue ?? "")
        update(\.hasAnswer, true)
        showFailure(message: nil, code: nil, sentence: nil)
    }

    /// A failed read leaves no answer: the list, path and detail clear and the field is disabled. A failed change
    /// keeps what the last answer showed, and the typed entry, so the person can reload and try again.
    private func fail(_ error: Error, isRead: Bool) {
        let toolError = error as? ToolError
        if isRead {
            update(\.supported, false)
            update(\.entries, [])
            update(\.configPath, "")
            update(\.detail, "")
            update(\.hasAnswer, false)
        }
        if case .unsupportedCommand(_, "mcp-allowlist", _)? = toolError {
            showFailure(message: nil, code: nil, sentence: MissingFeature.sentence(canDo: "edit global MCP approvals"))
        } else {
            showFailure(message: toolError?.displayMessage ?? error.localizedDescription, code: toolError?.detailCode, sentence: nil)
        }
    }

    private func showFailure(message: String?, code: String?, sentence: String?) {
        update(\.errorMessage, message)
        update(\.errorCode, code)
        update(\.missingFeatureSentence, sentence)
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<MCPAllowlistVM, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}
