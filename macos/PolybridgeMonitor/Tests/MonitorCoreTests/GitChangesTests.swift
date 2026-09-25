import XCTest
@testable import MonitorCore

final class DiffParserTests: XCTestCase {
    let patch = """
    diff --git a/Sources/App.swift b/Sources/App.swift
    index 1111111..2222222 100644
    --- a/Sources/App.swift
    +++ b/Sources/App.swift
    @@ -10,4 +10,5 @@ struct App {
         let a = 1
    -    let b = 2
    +    let b = 3
    +    let c = 4
         let d = 5
    @@ -40 +41 @@
    -old
    +new
    \\ No newline at end of file
    diff --git a/New.swift b/New.swift
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/New.swift
    @@ -0,0 +1,2 @@
    +line one
    +line two
    diff --git a/Gone.swift b/Gone.swift
    deleted file mode 100644
    --- a/Gone.swift
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    diff --git a/old name.txt b/new name.txt
    similarity 90%
    rename from old name.txt
    rename to new name.txt
    diff --git a/logo.png b/logo.png
    index 4444444..5555555 100644
    Binary files a/logo.png and b/logo.png differ
    """

    func testFilesHunksAndLineNumbers() throws {
        let files = DiffParser.parse(patch)
        XCTAssertEqual(files.map(\.path), ["Sources/App.swift", "New.swift", "Gone.swift", "new name.txt", "logo.png"])
        let app = files[0]
        XCTAssertEqual(app.hunks.count, 2)
        XCTAssertEqual(app.added, 3)
        XCTAssertEqual(app.removed, 2)
        let first = app.hunks[0].lines
        XCTAssertEqual(first.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(first[0].oldNumber, 10)
        XCTAssertEqual(first[0].newNumber, 10)
        XCTAssertEqual(first[1].oldNumber, 11)
        XCTAssertNil(first[1].newNumber)
        XCTAssertEqual(first[3].newNumber, 12)
        XCTAssertEqual(first[4].oldNumber, 12)
        XCTAssertEqual(first[4].newNumber, 13)
        XCTAssertEqual(app.hunks[1].lines.last?.kind, .noNewline)
        XCTAssertEqual(app.hunks[1].lines.first?.oldNumber, 40)
        XCTAssertEqual(app.hunks[1].lines[1].newNumber, 41)

        XCTAssertEqual(files[1].added, 2)
        XCTAssertNil(files[1].oldPath)
        XCTAssertEqual(files[2].removed, 1)
        XCTAssertEqual(files[3].oldPath, "old name.txt")
        XCTAssertTrue(files[3].hunks.isEmpty)
        XCTAssertTrue(files[4].isBinary)
    }

    func testQuotedPaths() {
        XCTAssertEqual(DiffParser.unquote("\"a/sp\\\"ace\\tx\""), "a/sp\"ace\tx")
        XCTAssertEqual(DiffParser.unquote("plain"), "plain")
    }

    func testNumstatAndNameStatusZ() {
        let numstat = Data("3\t1\tSources/App.swift\u{0}-\t-\tlogo.png\u{0}2\t0\t\u{0}old.txt\u{0}new.txt\u{0}".utf8)
        let counts = DiffParser.parseNumstat(numstat)
        XCTAssertEqual(counts["Sources/App.swift"]?.added, 3)
        XCTAssertEqual(counts["Sources/App.swift"]?.removed, 1)
        XCTAssertNotNil(counts["logo.png"])
        XCTAssertNil(counts["logo.png"]!.added, "binary numstat is '-'")
        XCTAssertEqual(counts["new.txt"]?.added, 2)

        let status = DiffParser.parseNameStatus(Data("M\u{0}Sources/App.swift\u{0}R087\u{0}old.txt\u{0}new.txt\u{0}A\u{0}N.swift\u{0}".utf8))
        XCTAssertEqual(status.map(\.status), ["M", "R", "A"])
        XCTAssertEqual(status[1].path, "new.txt")
        XCTAssertEqual(status[1].oldPath, "old.txt")
    }

    func testLabels() {
        XCTAssertEqual(GitChanges.labels(baseCommit: "abc", startDirty: false).count, 1)
        XCTAssertTrue(GitChanges(files: [], diffs: [], commitsSinceBase: 0, branch: nil, labels: [], comparedWithBase: true).summaryLine.hasPrefix("No files changed"))
        XCTAssertTrue(GitChanges.labels(baseCommit: nil, startDirty: nil).contains { $0.contains("No baseline commit") })
        XCTAssertTrue(GitChanges.labels(baseCommit: "abc", startDirty: true).contains { $0.contains("already had uncommitted changes") })
        XCTAssertTrue(GitChanges.labels(baseCommit: "abc", startDirty: nil).contains { $0.contains("unknown") })
    }

    func testOnlyHexCommitsAreUsed() {
        XCTAssertTrue(GitChanges.isSafeCommit("0123abcdef"))
        XCTAssertFalse(GitChanges.isSafeCommit("--output=/tmp/x"))
        XCTAssertFalse(GitChanges.isSafeCommit("HEAD"))
        XCTAssertFalse(GitChanges.isSafeCommit("abc"))
    }
}

final class GitInspectorTests: XCTestCase {
    func git(_ repo: URL, _ args: String...) throws {
        let output = try ProcessRunner.runBlocking(executable: "/usr/bin/git", arguments: ["-C", repo.path] + args, environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"], currentDirectory: nil, timeout: 30).get()
        XCTAssertEqual(output.exitCode, 0, "git \(args): \(output.stderr)")
    }

    func testChangesAgainstARealBaseline() async throws {
        let repo = try makeTempDir("pbm-git")
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "init", "-q", "-b", "main")
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        let base = try String(decoding: ProcessRunner.runBlocking(executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10).get().stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

        try "a\nB\nc\nd\n".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try "new\n".write(to: repo.appendingPathComponent("untracked file.txt"), atomically: true, encoding: .utf8)

        let inspector = GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
        let changes = await inspector.changes(repo: repo.path, baseCommit: base, startDirty: false)
        XCTAssertEqual(changes.branch, "main")
        XCTAssertEqual(changes.commitsSinceBase, 0)
        let byPath = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, $0) })
        XCTAssertEqual(byPath["kept.txt"]?.status, "M")
        XCTAssertEqual(byPath["kept.txt"]?.added, 2)
        XCTAssertEqual(byPath["kept.txt"]?.removed, 1)
        XCTAssertEqual(byPath["gone.txt"]?.status, "D")
        XCTAssertEqual(byPath["untracked file.txt"]?.status, "?")
        XCTAssertEqual(Set(changes.diffs.map(\.path)), ["kept.txt", "gone.txt"])
        XCTAssertTrue(changes.summaryLine.contains("3 files changed, +2 −2"), changes.summaryLine)
        XCTAssertTrue(changes.summaryLine.contains("Nothing committed"), changes.summaryLine)
    }

    func makeRepo() throws -> (URL, String) {
        let repo = try makeTempDir("pbm-git")
        try git(repo, "init", "-q", "-b", "main")
        try "a\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        let base = try String(decoding: ProcessRunner.runBlocking(executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10).get().stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, base)
    }

    func testAFailedComparisonNeverReadsAsNoChanges() async throws {
        let (repo, _) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let inspector = GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
        // A well-formed id that is not in this repo (another clone, or gc'd).
        let changes = await inspector.changes(repo: repo.path, baseCommit: "0123456789abcdef0123456789abcdef01234567", startDirty: false)
        XCTAssertFalse(changes.comparedWithBase)
        XCTAssertFalse(changes.failures.isEmpty)
        XCTAssertFalse(changes.summaryLine.contains("No files changed"), changes.summaryLine)
        XCTAssertTrue(changes.summaryLine.contains("could not be compared"), changes.summaryLine)

        let gone = await inspector.changes(repo: repo.appendingPathComponent("missing").path, baseCommit: "0123456789abcdef", startDirty: false)
        XCTAssertFalse(gone.comparedWithBase)
        XCTAssertFalse(gone.summaryLine.contains("No files changed"), gone.summaryLine)
    }

    func testUserDiffPrefixSettingsDoNotDetachPatchesFromFiles() async throws {
        let (repo, base) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "config", "diff.mnemonicPrefix", "true")
        try "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"]).changes(repo: repo.path, baseCommit: base, startDirty: false)
        XCTAssertTrue(changes.comparedWithBase)
        XCTAssertEqual(changes.files.map(\.path), ["f.txt"])
        XCTAssertEqual(changes.diffs.map(\.path), ["f.txt"], "the patch belongs to the listed file")
        try git(repo, "config", "diff.noprefix", "true")
        let noPrefix = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"]).changes(repo: repo.path, baseCommit: base, startDirty: false)
        XCTAssertEqual(noPrefix.diffs.map(\.path), ["f.txt"])
    }

    func testNoBaselineStillListsUntracked() async throws {
        let repo = try makeTempDir("pbm-git")
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "init", "-q")
        try "n\n".write(to: repo.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path]).changes(repo: repo.path, baseCommit: nil, startDirty: nil)
        XCTAssertEqual(changes.files.map(\.path), ["n.txt"])
        XCTAssertNil(changes.commitsSinceBase)
        XCTAssertFalse(changes.comparedWithBase)
        XCTAssertFalse(changes.summaryLine.contains("No files changed"), "without a baseline tracked files were never compared")
        XCTAssertTrue(changes.labels.contains { $0.contains("No baseline commit") })
    }

    /// A task that can write the repo can plant a textconv or clean-filter driver in .git/config
    /// (plus .gitattributes) or a core.fsmonitor command. Opening Changes must run none of them.
    func testRepoConfiguredCommandsNeverRunDuringChanges() async throws {
        let (repo, base) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sentinels = try makeTempDir("pbm-sentinel")
        defer { try? FileManager.default.removeItem(at: sentinels) }
        func sentinel(_ name: String) -> String { sentinels.appendingPathComponent(name).path }
        try "d\n".write(to: repo.appendingPathComponent("g.dat"), atomically: true, encoding: .utf8)
        try git(repo, "add", "g.dat")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "dat")
        let base2 = try String(decoding: ProcessRunner.runBlocking(executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10).get().stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = base
        let hook = repo.appendingPathComponent("fsm.sh")
        try "#!/bin/sh\ntouch '\(sentinel("fsmonitor"))'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(repo, "config", "diff.evil.textconv", "touch '\(sentinel("textconv"))'; cat")
        try git(repo, "config", "diff.evil.command", "touch '\(sentinel("diffcommand"))'; true")
        try git(repo, "config", "filter.evil.clean", "touch '\(sentinel("clean"))'; cat")
        try git(repo, "config", "filter.evil.process", "touch '\(sentinel("process"))'")
        try git(repo, "config", "core.fsmonitor", hook.path)
        try git(repo, "config", "diff.external", "touch '\(sentinel("external"))'; true")
        try "*.txt diff=evil\n*.dat filter=evil\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        try "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try "e\n".write(to: repo.appendingPathComponent("g.dat"), atomically: true, encoding: .utf8)
        // Same size and an old mtime: git must re-read (and would clean-filter) the content.
        let old = Date(timeIntervalSince1970: 1_000_000_000)
        for name in ["f.txt", "g.dat"] { try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: repo.appendingPathComponent(name).path) }

        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"]).changes(repo: repo.path, baseCommit: base2, startDirty: false)
        let fired = (try? FileManager.default.contentsOfDirectory(atPath: sentinels.path)) ?? []
        XCTAssertEqual(fired, [], "repo-configured commands ran: \(fired)")
        XCTAssertTrue(changes.comparedWithBase, "\(changes.failures)")
        XCTAssertEqual(Set(changes.diffs.map(\.path)), ["f.txt", "g.dat"])
    }

    func testDriverOverridesNeutraliseOnlyRepoScopedDrivers() {
        let listing = Data("global\u{0}filter.lfs.clean\ngit-lfs clean -- %f\u{0}local\u{0}filter.evil.clean\ntouch x\u{0}local\u{0}diff.a b.textconv\ncat\u{0}worktree\u{0}filter.w.process\nx\u{0}local\u{0}diff.bare.binary\u{0}".utf8)
        let overrides = GitInspector.driverOverrides(listing)
        XCTAssertTrue(overrides.contains("filter.evil.clean="))
        XCTAssertTrue(overrides.contains("filter.evil.process="))
        XCTAssertTrue(overrides.contains("filter.evil.required=false"))
        XCTAssertTrue(overrides.contains("diff.a b.textconv="))
        XCTAssertTrue(overrides.contains("diff.a b.command="))
        XCTAssertTrue(overrides.contains("filter.w.clean="))
        XCTAssertFalse(overrides.contains { $0.hasPrefix("filter.lfs.") }, "the user's own global drivers are left alone")
    }

    func testArgvNeverContainsAShell() {
        let argv = GitInspector.argv(repo: "/r; rm -rf /", ["status"])
        XCTAssertEqual(Array(argv.prefix(2)), ["-C", "/r; rm -rf /"])
        XCTAssertEqual(argv.last, "status")
        for pinned in ["core.fsmonitor=false", "core.hooksPath=/dev/null", "diff.external=", "core.quotepath=off"] {
            XCTAssertTrue(argv.contains(pinned), pinned)
        }
    }
}
