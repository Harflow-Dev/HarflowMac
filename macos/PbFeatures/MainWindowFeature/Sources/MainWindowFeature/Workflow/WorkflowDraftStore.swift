import CryptoKit
import Foundation
import MonitorCore

// MARK: - WorkflowDraftStore

@MainActor
protocol WorkflowDraftStoring {
    func load(key: String) throws -> [String: JSONValue]?
    func save(_ draft: [String: JSONValue], key: String) throws
    func remove(key: String) throws
}

/// Local editor state is separate from validated, executable workflow definitions.
@MainActor
final class WorkflowDraftStore: WorkflowDraftStoring {
    private let directory: URL

    init(directory: URL) { self.directory = directory }

    static func applicationStore() -> WorkflowDraftStore {
        let home = ProcessInfo.processInfo.environment["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let root = home.appendingPathComponent("Library/Application Support", isDirectory: true)
        return WorkflowDraftStore(directory: root.appendingPathComponent("Polybridge/WorkflowDrafts", isDirectory: true))
    }

    func load(key: String) throws -> [String: JSONValue]? {
        let file = url(key)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard let draft = JSONValue.parse(try Data(contentsOf: file))?.objectValue else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return draft
    }

    func save(_ draft: [String: JSONValue], key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(JSONValue.object(draft).rendered().utf8).write(to: url(key), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(key).path)
    }

    func remove(key: String) throws {
        let file = url(key)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func url(_ key: String) -> URL {
        let hash = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash + ".json")
    }
}
