//
//  ScratchDefaults.swift
//  HfTestUtilities
//

import Foundation

/// A throwaway `UserDefaults` suite that never touches the user's `~/Library/Preferences` folder.
///
/// A suite named by an absolute path is stored at `<path>.plist` rather than in the Preferences
/// folder, so each instance lives in its own directory under the temporary directory. Call
/// ``remove()`` unconditionally when the test is done: `removePersistentDomain(forName:)` alone leaves
/// an empty plist behind, so the directory is deleted as well.
public final class ScratchDefaults: @unchecked Sendable {
    /// The directory that holds the suite's plist.
    public let directory: URL
    /// The absolute-path suite name, for reopening the same suite.
    public let suiteName: String
    /// The suite instance created for this scratch directory.
    public let defaults: UserDefaults

    /// Creates a fresh scratch suite in a new directory under the temporary directory.
    /// - Parameter label: The file name of the suite inside its directory.
    public init(label: String = "suite") {
        var base = FileManager.default.temporaryDirectory.standardizedFileURL
        if !base.path.hasPrefix("/") {
            base = URL(fileURLWithPath: NSTemporaryDirectory()).absoluteURL.standardizedFileURL
        }
        let directory = base.appendingPathComponent("harflow-defaults-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Could not create scratch defaults directory at \(directory.path): \(error)")
        }
        let name = directory.appendingPathComponent(label).path
        precondition(name.hasPrefix("/"), "Scratch suite name must be an absolute path")
        self.directory = directory
        self.suiteName = name
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Could not create scratch UserDefaults suite at \(name)")
        }
        self.defaults = defaults
    }

    /// Returns a new `UserDefaults` instance on the same suite path.
    public func reopen() -> UserDefaults {
        guard let reopened = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("Could not reopen scratch UserDefaults suite at \(suiteName)")
        }
        return reopened
    }

    /// Removes the suite's domain and deletes its directory. Safe to call more than once.
    public func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults.synchronize()
        try? FileManager.default.removeItem(at: directory)
    }
}
