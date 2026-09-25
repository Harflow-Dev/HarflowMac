import Foundation

public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case context, added, removed, noNewline }
    public let kind: Kind
    public let text: String
    public let oldNumber: Int?
    public let newNumber: Int?
}

public struct DiffHunk: Equatable, Sendable {
    public let header: String
    public let lines: [DiffLine]
}

public struct DiffFile: Equatable, Identifiable, Sendable {
    public var id: String { path }
    public let path: String
    public let oldPath: String?
    public let isBinary: Bool
    public let hunks: [DiffHunk]

    public var added: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .added }.count } }
    public var removed: Int { hunks.reduce(0) { $0 + $1.lines.filter { $0.kind == .removed }.count } }
}

/// One changed path, from `--name-status -z` joined with `--numstat -z`.
public struct FileChange: Equatable, Identifiable, Sendable {
    public var id: String { path }
    /// `M`, `A`, `D`, `R`, `C`, `T`, or `?` for untracked.
    public let status: String
    public let path: String
    public let oldPath: String?
    /// nil for a binary file (numstat prints `-`) or an untracked one.
    public let added: Int?
    public let removed: Int?

    public var isUntracked: Bool { status == "?" }
}

public enum DiffParser {
    /// Parse `git diff` (unified, `--no-color`) into files and hunks, numbering lines old/new.
    public static func parse(_ text: String) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var oldPath: String?
        var binary = false
        var hunks: [DiffHunk] = []
        var hunkHeader: String?
        var lines: [DiffLine] = []
        var oldLine = 0, newLine = 0
        var headerPaths: (old: String?, new: String?) = (nil, nil)

        func closeHunk() {
            if let header = hunkHeader { hunks.append(DiffHunk(header: header, lines: lines)) }
            hunkHeader = nil
            lines = []
        }
        func closeFile() {
            closeHunk()
            let resolved = path ?? headerPaths.new ?? headerPaths.old
            if let resolved {
                let old = oldPath ?? (headerPaths.old != resolved ? headerPaths.old : nil)
                files.append(DiffFile(path: resolved, oldPath: old, isBinary: binary, hunks: hunks))
            }
            path = nil; oldPath = nil; binary = false; hunks = []; headerPaths = (nil, nil)
        }

        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            if line.hasPrefix("diff --git ") {
                closeFile()
                headerPaths = gitHeaderPaths(String(line.dropFirst("diff --git ".count)))
                continue
            }
            if hunkHeader == nil {
                if line.hasPrefix("--- ") {
                    let value = stripPrefix(unquote(String(line.dropFirst(4))), "a/")
                    if value != "/dev/null" { oldPath = value }
                } else if line.hasPrefix("+++ ") {
                    let value = stripPrefix(unquote(String(line.dropFirst(4))), "b/")
                    path = value == "/dev/null" ? oldPath : value
                    if value != "/dev/null", oldPath == value { oldPath = nil }
                } else if line.hasPrefix("rename from ") {
                    oldPath = unquote(String(line.dropFirst("rename from ".count)))
                } else if line.hasPrefix("rename to ") {
                    path = unquote(String(line.dropFirst("rename to ".count)))
                } else if line.hasPrefix("Binary files ") {
                    binary = true
                }
            }
            if line.hasPrefix("@@") {
                closeHunk()
                hunkHeader = line
                (oldLine, newLine) = hunkStarts(line)
                continue
            }
            guard hunkHeader != nil else { continue }
            if line.hasPrefix("+") {
                lines.append(DiffLine(kind: .added, text: String(line.dropFirst()), oldNumber: nil, newNumber: newLine))
                newLine += 1
            } else if line.hasPrefix("-") {
                lines.append(DiffLine(kind: .removed, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: nil))
                oldLine += 1
            } else if line.hasPrefix(" ") {
                lines.append(DiffLine(kind: .context, text: String(line.dropFirst()), oldNumber: oldLine, newNumber: newLine))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                lines.append(DiffLine(kind: .noNewline, text: line, oldNumber: nil, newNumber: nil))
            } else if line.isEmpty {
                continue
            } else {
                // Anything else ends the hunk (the next file's extended header, say).
                closeHunk()
            }
        }
        closeFile()
        return files
    }

    /// `@@ -12,5 +12,7 @@ func` → (12, 12). A count-less range (`-3`) starts at 3.
    static func hunkStarts(_ header: String) -> (Int, Int) {
        var old = 0, new = 0
        for token in header.split(separator: " ") {
            if token.hasPrefix("-"), let value = Int(token.dropFirst().split(separator: ",").first ?? "") { old = value }
            if token.hasPrefix("+"), let value = Int(token.dropFirst().split(separator: ",").first ?? "") { new = value }
        }
        return (old, new)
    }

    /// `a/x b/x` → (x, x). Only used when a file has no `---`/`+++` lines (mode-only, binary).
    static func gitHeaderPaths(_ rest: String) -> (old: String?, new: String?) {
        guard let range = rest.range(of: " b/", options: .backwards) else { return (nil, nil) }
        let old = stripPrefix(unquote(String(rest[..<range.lowerBound])), "a/")
        let new = unquote(String(rest[range.upperBound...]))
        return (old, new)
    }

    static func stripPrefix(_ value: String, _ prefix: String) -> String {
        value.hasPrefix(prefix) ? String(value.dropFirst(prefix.count)) : value
    }

    /// git C-quotes a path with unusual bytes: `"a/sp\"ace"`. Undo the common escapes.
    static func unquote(_ value: String) -> String {
        let trimmed = value.split(separator: "\t").first.map(String.init) ?? value
        guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
        var out = ""
        var iterator = trimmed.dropFirst().dropLast().makeIterator()
        while let char = iterator.next() {
            guard char == "\\", let next = iterator.next() else { out.append(char); continue }
            switch next {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "\"": out.append("\"")
            case "\\": out.append("\\")
            default: out.append(next)
            }
        }
        return out
    }

    /// `git diff --numstat -z`: `added\tremoved\tpath\0`, or for a rename
    /// `added\tremoved\t\0old\0new\0`. Keyed by the new path.
    public static func parseNumstat(_ data: Data) -> [String: (added: Int?, removed: Int?)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [String: (Int?, Int?)] = [:]
        var index = 0
        while index < fields.count {
            let parts = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            index += 1
            guard parts.count == 3 else { continue }
            let added = Int(parts[0]), removed = Int(parts[1])
            if parts[2].isEmpty {
                guard index + 1 < fields.count else { break }
                result[fields[index + 1]] = (added, removed)
                index += 2
            } else {
                result[String(parts[2])] = (added, removed)
            }
        }
        return result
    }

    /// `git diff --name-status -z`: `M\0path\0`, `R100\0old\0new\0`.
    public static func parseNameStatus(_ data: Data) -> [(status: String, path: String, oldPath: String?)] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var result: [(String, String, String?)] = []
        var index = 0
        while index < fields.count {
            let code = fields[index]
            index += 1
            guard let letter = code.first, !code.isEmpty else { continue }
            if letter == "R" || letter == "C" {
                guard index + 1 < fields.count else { break }
                result.append((String(letter), fields[index + 1], fields[index]))
                index += 2
            } else {
                guard index < fields.count else { break }
                result.append((String(letter), fields[index], nil))
                index += 1
            }
        }
        return result
    }
}

/// The Changes tab: what git says changed in the repo since the task's `base_commit`, never what
/// the agent reported. Anything else that touched the worktree meanwhile shows here too, and the
/// labels say so.
public struct GitFailure: Error, Equatable, Sendable {
    public let query: String
    public let detail: String
}

public struct GitChanges: Equatable, Sendable {
    public var files: [FileChange]
    public var diffs: [DiffFile]
    public var commitsSinceBase: Int?
    public var branch: String?
    public var labels: [String]
    /// True only when every query of the comparison against `base_commit` (untracked listing
    /// included) succeeded. When
    /// false, `files` holds untracked files at most, and nothing may be said about tracked ones.
    public var comparedWithBase: Bool
    public var failures: [GitFailure]

    public init(files: [FileChange], diffs: [DiffFile], commitsSinceBase: Int?, branch: String?, labels: [String], comparedWithBase: Bool, failures: [GitFailure] = []) {
        self.files = files
        self.diffs = diffs
        self.commitsSinceBase = commitsSinceBase
        self.branch = branch
        self.labels = labels
        self.comparedWithBase = comparedWithBase
        self.failures = failures
    }

    public var totalAdded: Int { files.compactMap(\.added).reduce(0, +) }
    public var totalRemoved: Int { files.compactMap(\.removed).reduce(0, +) }

    /// The banner line for the finished view, from git alone. It never says "no files changed"
    /// unless the comparison against the baseline actually ran.
    public var summaryLine: String {
        guard comparedWithBase else {
            let untracked = files.filter(\.isUntracked).count
            var line = "Tracked changes could not be compared with the task's baseline"
            if let failure = failures.first { line += " (git \(failure.query): \(failure.detail))" }
            line += "."
            if untracked > 0 { line += " \(untracked) untracked file\(untracked == 1 ? "" : "s") listed below." }
            return line
        }
        let count = files.count
        var line = count == 0 ? "No files changed" : "\(count) file\(count == 1 ? "" : "s") changed, +\(totalAdded) −\(totalRemoved)"
        if let commits = commitsSinceBase {
            line += commits == 0 ? ". Nothing committed since the task started." : ". \(commits) commit\(commits == 1 ? "" : "s") since the task started."
        }
        return line
    }

    /// The A1.2 labels: a baseline that was missing or dirty changes what the diff means.
    public static func labels(baseCommit: String?, startDirty: Bool?) -> [String] {
        var labels = ["From git in the repo, not the agent's report. Anything else that changed the working tree since the task started shows here too."]
        if baseCommit == nil {
            labels.append("No baseline commit was recorded when this task started (no commits yet, or the probe failed), so its changes cannot be separated from the rest of the repo.")
        }
        switch startDirty {
        case .some(true):
            labels.append("The repo already had uncommitted changes when the task started; they are included below.")
        case .none where baseCommit != nil:
            labels.append("Whether the repo was clean when the task started is unknown; uncommitted changes from before it may be included.")
        default:
            break
        }
        return labels
    }

    /// Accept only a plain hex object name, so a hostile record can never inject a git option.
    public static func isSafeCommit(_ value: String) -> Bool {
        (4...64).contains(value.count) && value.allSatisfy { $0.isHexDigit }
    }
}

public struct GitInspector: Sendable {
    public var git: String
    public var environment: [String: String]
    public var runner: ProcessRunning

    public init(git: String = "/usr/bin/git", environment: [String: String], runner: ProcessRunning = ProcessRunner()) {
        self.git = git
        self.environment = environment
        self.runner = runner
    }

    /// Settings that stop these read-only questions from running anything a repository configured.
    /// A task that can write the repo can plant commands in `.git/config`: `core.fsmonitor` runs on
    /// every index refresh (diff and ls-files), `diff.external` / `diff.<d>.command` on a diff
    /// (also off via `--no-ext-diff`), `diff.<d>.textconv` (also off via `--no-textconv`), and
    /// `filter.<d>.clean`/`process` whenever git re-reads a worktree file. Hooks do not fire for
    /// these commands, but `core.hooksPath` is pinned too so no future call can pick one up.
    static let hardening = [
        "-c", "core.fsmonitor=false",
        "-c", "core.hooksPath=/dev/null",
        "-c", "diff.external=",
        "-c", "core.quotepath=off",
        "--no-pager",
    ]

    /// The fixed argv for each question: `-C <repo>`, the hardening, per-repo driver overrides,
    /// then the command. Never through a shell.
    public static func argv(repo: String, overrides: [String] = [], _ rest: [String]) -> [String] {
        ["-C", repo] + hardening + overrides.flatMap { ["-c", $0] } + rest
    }

    /// `-c` values that disable every diff/filter driver the *repository* defines (local or
    /// worktree scope, includes resolved), from `git config --show-scope -z --get-regexp`. An empty
    /// command is no command to git. The user's own global/system drivers (git-lfs, say) are left
    /// alone: the repository cannot write those, and disabling them would misreport LFS files.
    static func driverOverrides(_ listing: Data) -> [String] {
        let fields = listing.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        var filters: [String] = [], diffs: [String] = []
        var index = 0
        while index + 1 < fields.count {
            let scope = fields[index]
            let key = fields[index + 1].split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
            index += 2
            guard scope != "global", scope != "system" else { continue }
            let lower = key.lowercased()
            for (prefix, list) in [("filter.", 0), ("diff.", 1)] where lower.hasPrefix(prefix) {
                // `filter.<name>.<var>`: the name is everything between the first and last dot.
                guard let lastDot = key.lastIndex(of: "."), lastDot > key.index(key.startIndex, offsetBy: prefix.count) else { continue }
                let name = String(key[key.index(key.startIndex, offsetBy: prefix.count)..<lastDot])
                if list == 0 { if !filters.contains(name) { filters.append(name) } } else if !diffs.contains(name) { diffs.append(name) }
            }
        }
        return filters.flatMap { ["filter.\($0).clean=", "filter.\($0).smudge=", "filter.\($0).process=", "filter.\($0).required=false"] }
            + diffs.flatMap { ["diff.\($0).textconv=", "diff.\($0).command="] }
    }

    /// stdout, or a one-line reason the query failed (non-zero exit, timeout, git missing).
    func run(_ repo: String, overrides: [String] = [], _ rest: [String], allowExit1Empty: Bool = false) async -> Result<Data, GitFailure> {
        let what = rest.first ?? "git"
        // No optional index writes: these are questions, not maintenance.
        var env = environment
        env["GIT_OPTIONAL_LOCKS"] = "0"
        env["GIT_TERMINAL_PROMPT"] = "0"
        switch await runner.run(executable: git, arguments: Self.argv(repo: repo, overrides: overrides, rest), environment: env, currentDirectory: nil, timeout: 20) {
        case .success(let output) where allowExit1Empty && output.exitCode == 1 && output.stdout.isEmpty && !output.timedOut:
            return .success(Data())
        case .failure(let error):
            return .failure(GitFailure(query: what, detail: error.message))
        case .success(let output) where output.timedOut:
            return .failure(GitFailure(query: what, detail: "timed out"))
        case .success(let output) where output.exitCode != 0:
            let detail = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(GitFailure(query: what, detail: detail.isEmpty ? "exit \(output.exitCode)" : String(detail.prefix(300))))
        case .success(let output):
            return .success(output.stdout)
        }
    }

    public func changes(repo: String, baseCommit: String?, startDirty: Bool?) async -> GitChanges {
        let labels = GitChanges.labels(baseCommit: baseCommit, startDirty: startDirty)
        var failures: [GitFailure] = []
        func take(_ result: Result<Data, GitFailure>) -> Data? {
            switch result {
            case .success(let data): return data
            case .failure(let failure): failures.append(failure); return nil
            }
        }
        // Read which drivers the repository defines before any command that could run one. If
        // that cannot be read, nothing that diffs is run at all (fail closed).
        let listing = take(await run(repo, ["config", "--show-scope", "-z", "--get-regexp", "^(filter|diff)\\."], allowExit1Empty: true))
        let overrides = listing.map(Self.driverOverrides)
        let branch = take(await run(repo, ["rev-parse", "--abbrev-ref", "HEAD"])).map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        let untrackedResult = overrides == nil ? nil : take(await run(repo, overrides: overrides ?? [], ["ls-files", "--others", "--exclude-standard", "-z"]))
        let untracked = (untrackedResult ?? Data()).split(separator: 0).map { String(decoding: $0, as: UTF8.self) }.filter { !$0.isEmpty }

        var files: [FileChange] = []
        var diffs: [DiffFile] = []
        var commits: Int?
        var compared = false
        if let base = baseCommit, GitChanges.isSafeCommit(base), let overrides {
            // Prefixes pinned: a user's diff.mnemonicPrefix / diff.noprefix would otherwise change
            // what the parser sees and detach each patch from its file.
            let common = ["--no-color", "--no-ext-diff", "--no-textconv", "--find-renames", "--src-prefix=a/", "--dst-prefix=b/", base, "--"]
            let numstatData = take(await run(repo, overrides: overrides, ["diff", "--numstat", "-z"] + common))
            let statusData = take(await run(repo, overrides: overrides, ["diff", "--name-status", "-z"] + common))
            let patch = take(await run(repo, overrides: overrides, ["diff", "--unified=3"] + common))
            if let numstatData, let statusData, let patch, untrackedResult != nil {
                compared = true
                let numstat = DiffParser.parseNumstat(numstatData)
                for entry in DiffParser.parseNameStatus(statusData) {
                    let counts = numstat[entry.path]
                    files.append(FileChange(status: entry.status, path: entry.path, oldPath: entry.oldPath, added: counts?.added ?? nil, removed: counts?.removed ?? nil))
                }
                diffs = DiffParser.parse(String(decoding: patch, as: UTF8.self))
            }
            commits = take(await run(repo, overrides: overrides, ["rev-list", "--count", "\(base)..HEAD"])).flatMap { Int(String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
        for path in untracked where !files.contains(where: { $0.path == path }) {
            files.append(FileChange(status: "?", path: path, oldPath: nil, added: nil, removed: nil))
        }
        return GitChanges(files: files, diffs: diffs, commitsSinceBase: commits, branch: branch, labels: labels, comparedWithBase: compared, failures: failures)
    }
}
