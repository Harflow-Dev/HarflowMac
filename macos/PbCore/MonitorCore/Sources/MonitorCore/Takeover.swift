import Foundation

/// "Open in Terminal.app": Terminal.app can only be handed a file to run, so the handover is a
/// fixed script plus NUL-separated data files in a private directory. The script's text never
/// contains the argv, the task id or any path from polybridge — it reads them as data — so nothing
/// from a task is ever interpreted by a shell. The script attaches its own pid (`$$`) and then
/// `exec`s the CLI in that same pid, removing its files first.
public enum TerminalAppHandoff {
    public static let scriptName = "takeover.command"
    public static let metaName = "meta"
    public static let argvName = "argv"

    /// Fixed text. `(0)` splits the file on NUL bytes; `$(<file)` keeps NULs in zsh.
    public static let script = """
    #!/bin/zsh -l
    emulate -L zsh
    here=${0:A:h}
    meta=(${(0)"$(<$here/meta)"})
    cmd=(${(0)"$(<$here/argv)"})
    rm -f -- $here/meta $here/argv $here/takeover.command
    rmdir -- $here 2>/dev/null
    # Terminal.app's own environment, not the app's, reaches this script: drop every PB_* name.
    unset -m 'PB_*'
    export PB_OPEN_MONITOR=0
    if (( ${#meta} != 3 || ${#cmd} == 0 )); then
      print -u2 "polybridge: the takeover hand-off files are incomplete"; exit 1
    fi
    cd -- $meta[3] || exit 1
    if ! $meta[1] takeover-attach --pid=$$ --json -- $meta[2] >/dev/null; then
      print -u2 "polybridge: the takeover could not be attached to this terminal; not starting the session"
      exit 1
    fi
    exec -- $cmd
    """

    public struct Files: Equatable, Sendable {
        public let script: String
        public let meta: Data
        public let argv: Data
    }

    public enum BuildError: Error, Equatable { case emptyArgv, nulInValue, relativePath }

    static func nulJoined(_ values: [String]) throws -> Data {
        var data = Data()
        for value in values {
            guard !value.contains("\u{0}") else { throw BuildError.nulInValue }
            guard !value.isEmpty else { throw BuildError.emptyArgv }
            data.append(Data(value.utf8))
            data.append(0)
        }
        return data
    }

    public static func files(ctl: String, taskID: String, grant: TakeoverGrant) throws -> Files {
        guard !grant.argv.isEmpty else { throw BuildError.emptyArgv }
        guard ctl.hasPrefix("/"), grant.cwd.hasPrefix("/") else { throw BuildError.relativePath }
        return Files(script: script, meta: try nulJoined([ctl, taskID, grant.cwd]), argv: try nulJoined(grant.argv))
    }

    /// Write the three files into a fresh 0700 directory under `parent`; returns the script path.
    public static func write(_ files: Files, under parent: URL) throws -> URL {
        let dir = parent.appendingPathComponent("takeover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let scriptURL = dir.appendingPathComponent(scriptName)
        try files.meta.write(to: dir.appendingPathComponent(metaName), options: .withoutOverwriting)
        try files.argv.write(to: dir.appendingPathComponent(argvName), options: .withoutOverwriting)
        try Data(files.script.utf8).write(to: scriptURL, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

/// `polybridge-monitor://task/<id>`. The id must match polybridge's own task id pattern; anything
/// else is ignored rather than turned into a lookup.
public enum MonitorURL {
    public static let scheme = "polybridge-monitor"

    public static func taskID(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == "task" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 1, isValidTaskID(parts[0]) else { return nil }
        return parts[0]
    }

    /// `[A-Za-z0-9][A-Za-z0-9_-]{0,63}`, as `store.TASK_ID_PATTERN`.
    public static func isValidTaskID(_ value: String) -> Bool {
        guard let first = value.unicodeScalars.first, value.unicodeScalars.count <= 64 else { return false }
        func alnum(_ s: Unicode.Scalar) -> Bool { s.isASCII && (CharacterSet.alphanumerics.contains(s)) }
        guard alnum(first) else { return false }
        return value.unicodeScalars.allSatisfy { alnum($0) || $0 == "_" || $0 == "-" }
    }
}
