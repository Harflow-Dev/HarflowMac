import Darwin
import Foundation

// MARK: - ManagedRuntimeFileLock

/// One permanent, private lock file coordinates writers without replacing its inode.
final class ManagedRuntimeFileLock {
    private let descriptor: Int32

    init(path: String) throws {
        self.descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ManagedRuntimeFailure("Cannot open the managed runtime installation lock.") }
        var information = stat()
        guard fstat(descriptor, &information) == 0, information.st_uid == getuid(),
              information.st_mode & S_IFMT == S_IFREG, information.st_nlink == 1,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw ManagedRuntimeFailure("Managed runtime installation is in progress in another process. Try again after it finishes.")
        }
        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            flock(descriptor, LOCK_UN)
            close(descriptor)
            throw ManagedRuntimeFailure("Cannot protect the managed runtime installation lock.")
        }
    }

    deinit {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}

// MARK: - ManagedRuntimeFiles

/// Narrow filesystem operations confined to the managed executable root, never the task store.
enum ManagedRuntimeFiles {
    static func kind(_ path: String) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType
    }

    static func privateDirectory(_ path: String) throws {
        if let kind = kind(path) {
            guard kind == .typeDirectory else { throw ManagedRuntimeFailure("Managed runtime directory is not a regular directory: " + path) }
        } else {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    static func prepareRoot(_ layout: ManagedRuntimeLayout) throws {
        guard !layout.home.isEmpty, layout.home != "/" else { throw ManagedRuntimeFailure("A valid home is required for the managed runtime.") }
        var path = layout.home
        guard kind(path) == .typeDirectory else { throw ManagedRuntimeFailure("The selected home is not a directory.") }
        for component in ["Library", "Application Support", "Harflow", "Runtime"] {
            path += "/" + component
            try privateDirectory(path)
        }
        try privateDirectory(layout.generationsDirectory)
        try privateDirectory(layout.binDirectory)
    }

    static func reapStaging(_ layout: ManagedRuntimeLayout) throws {
        let entries = try FileManager.default.contentsOfDirectory(atPath: layout.runtimeRoot)
        guard entries.count <= 4096 else { throw ManagedRuntimeFailure("Managed runtime directory has too many entries.") }
        for name in entries where name.hasPrefix(".staging-") {
            let suffix = String(name.dropFirst(".staging-".count))
            guard UUID(uuidString: suffix) != nil else { continue }
            let path = layout.runtimeRoot + "/" + name
            if kind(path) == .typeDirectory { try FileManager.default.removeItem(atPath: path) }
        }
    }

    static func executable(_ text: String, at path: String) throws {
        if let kind = kind(path), kind != .typeRegular {
            throw ManagedRuntimeFailure("Refusing a foreign managed runtime launcher.")
        }
        try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}

// MARK: - ManagedRuntimeReceipt

struct ManagedRuntimeReceipt: Codable {
    let schema: Int
    let specification: String
    let engineVersion: String
    let generation: String
    let stateRoot: String
    let engineSHA256: String
    let engineYanked: Bool
    let engineYankedReason: String?
}
