import CryptoKit
import Darwin
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
        return WorkflowDraftStore(directory: root.appendingPathComponent("Harflow/WorkflowDrafts", isDirectory: true))
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
        let temporary = directory.appendingPathComponent(".draft-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        // Ownership begins only after exclusive creation; failure never removes a foreign path.
        var published = false
        defer { if !published { unlink(temporary.path) } }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closeAttempted = false
        defer { if !closeAttempted { try? handle.close() } }
        try handle.write(contentsOf: Data(JSONValue.object(draft).rendered().utf8))
        closeAttempted = true
        try handle.close()
        guard rename(temporary.path, url(key).path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        published = true
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
