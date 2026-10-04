import Foundation

// MARK: - WorkflowCommandInputs

/// Moves logical workflow payload options into disposable files at the process boundary.
struct WorkflowCommandInputs {
    let options: [String]
    private let directory: URL?

    static func prepare(options: [String]) throws -> Self {
        try Self(options: options, root: FileManager.default.temporaryDirectory) { data, url in
            try data.write(to: url, options: .atomic)
        }
    }

    init(options: [String], root: URL, write: (Data, URL) throws -> Void) throws {
        let payloads = [("--definition-json=", "--definition=", "definition.json"),
                        ("--source=", "--source-file=", "source.json"),
                        ("--prompt=", "--prompt-file=", "prompt.txt")]
        guard options.contains(where: { option in payloads.contains { option.hasPrefix($0.0) } }) else {
            self.options = options
            self.directory = nil
            return
        }
        let folder = root.appendingPathComponent("polybridge-builder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var transported: [String] = []
            for option in options {
                guard let (prefix, replacement, filename) = payloads.first(where: { option.hasPrefix($0.0) }) else {
                    transported.append(option)
                    continue
                }
                let file = folder.appendingPathComponent(filename)
                try write(Data(option.dropFirst(prefix.count).utf8), file)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                transported.append(replacement + file.path)
            }
            self.options = transported
            self.directory = folder
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    func cleanUp() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }
}
