import Darwin
import Foundation

// MARK: - PrivateJSONInput

/// Owns one exclusively created private directory and JSON input file.
struct PrivateJSONInput {
    let file: URL
    private let directory: URL

    init(data: Data, filename: String, baseDirectory: String?, identifier: UUID = UUID()) throws {
        guard ["definition.json", "request.json"].contains(filename) else { throw CocoaError(.fileWriteInvalidFileName) }
        let manager = FileManager.default
        let base = try Self.baseDirectory(baseDirectory)
        let directory = base.appendingPathComponent("harflow-workflow-\(identifier.uuidString)", isDirectory: true)
        guard mkdir(directory.path, S_IRWXU) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // A successful exclusive mkdir, never an existing path, grants cleanup ownership.
        let file = directory.appendingPathComponent(filename)
        do {
            try Self.writeDefinition(data, to: file)
        } catch {
            try? manager.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.file = file
    }

    private static func baseDirectory(_ path: String?) throws -> URL {
        guard let path else { return FileManager.default.temporaryDirectory }
        guard !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              path.hasPrefix("/"), !path.contains("\0") else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CocoaError(.fileNoSuchFile)
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw CocoaError(.fileWriteNoPermission) }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private static func writeDefinition(_ data: Data, to file: URL) throws {
        let descriptor = open(file.path, O_CREAT | O_EXCL | O_NOFOLLOW | O_WRONLY, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var closeAttempted = false
        defer { if !closeAttempted { try? handle.close() } }
        try handle.write(contentsOf: data)
        closeAttempted = true
        try handle.close()
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: directory)
    }
}
