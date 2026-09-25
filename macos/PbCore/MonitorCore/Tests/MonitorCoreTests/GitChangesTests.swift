import Foundation
@testable import MonitorCore
import Testing

@Suite
struct DiffParserTests {
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

    @Test
    func givenAMultiFilePatch_whenParsed_thenFilesHunksAndLineNumbersAreCorrect() throws {
        // given / when
        let files = DiffParser.parse(patch)
        // then
        #expect(files.map(\.path) == ["Sources/App.swift", "New.swift", "Gone.swift", "new name.txt", "logo.png"])
        let app = files[0]
        #expect(app.hunks.count == 2)
        #expect(app.added == 3)
        #expect(app.removed == 2)
        let first = app.hunks[0].lines
        #expect(first.map(\.kind) == [.context, .removed, .added, .added, .context])
        #expect(first[0].oldNumber == 10)
        #expect(first[0].newNumber == 10)
        #expect(first[1].oldNumber == 11)
        #expect(first[1].newNumber == nil)
        #expect(first[3].newNumber == 12)
        #expect(first[4].oldNumber == 12)
        #expect(first[4].newNumber == 13)
        #expect(app.hunks[1].lines.last?.kind == .noNewline)
        #expect(app.hunks[1].lines.first?.oldNumber == 40)
        #expect(app.hunks[1].lines[1].newNumber == 41)

        #expect(files[1].added == 2)
        #expect(files[1].oldPath == nil)
        #expect(files[2].removed == 1)
        #expect(files[3].oldPath == "old name.txt")
        #expect(files[3].hunks.isEmpty)
        #expect(files[4].isBinary)
    }

    @Test
    func givenQuotedGitPaths_whenUnquoted_thenEscapesAreResolved() {
        // given / when / then
        #expect(DiffParser.unquote("\"a/sp\\\"ace\\tx\"") == "a/sp\"ace\tx")
        #expect(DiffParser.unquote("plain") == "plain")
    }

    @Test
    func givenNumstatAndNameStatusZOutput_whenParsed_thenCountsAndStatusesMatch() {
        // given
        let numstat = Data("3\t1\tSources/App.swift\u{0}-\t-\tlogo.png\u{0}2\t0\t\u{0}old.txt\u{0}new.txt\u{0}".utf8)
        // when
        let counts = DiffParser.parseNumstat(numstat)
        // then
        #expect(counts["Sources/App.swift"]?.added == 3)
        #expect(counts["Sources/App.swift"]?.removed == 1)
        #expect(counts["logo.png"] != nil)
        #expect(counts["logo.png"]!.added == nil, "binary numstat is '-'")
        #expect(counts["new.txt"]?.added == 2)

        let status = DiffParser.parseNameStatus(Data("M\u{0}Sources/App.swift\u{0}R087\u{0}old.txt\u{0}new.txt\u{0}A\u{0}N.swift\u{0}".utf8))
        #expect(status.map(\.status) == ["M", "R", "A"])
        #expect(status[1].path == "new.txt")
        #expect(status[1].oldPath == "old.txt")
    }

    @Test
    func givenBaselineAndDirtyCombinations_whenBuildingLabels_thenTheRightCaveatsAppear() {
        // given / when / then
        #expect(GitChanges.labels(baseCommit: "abc", startDirty: false).count == 1)
        #expect(
            GitChanges(files: [], diffs: [], commitsSinceBase: 0, branch: nil, labels: [], comparedWithBase: true)
                .summaryLine
.hasPrefix("No files changed")
        )
        #expect(GitChanges.labels(baseCommit: nil, startDirty: nil).contains { $0.contains("No baseline commit") })
        #expect(GitChanges.labels(baseCommit: "abc", startDirty: true).contains { $0.contains("already had uncommitted changes") })
        #expect(GitChanges.labels(baseCommit: "abc", startDirty: nil).contains { $0.contains("unknown") })
    }

    @Test
    func givenCommitLikeStrings_whenCheckedForSafety_thenOnlyHexCommitsPass() {
        // given / when / then
        #expect(GitChanges.isSafeCommit("0123abcdef"))
        #expect(!GitChanges.isSafeCommit("--output=/tmp/x"))
        #expect(!GitChanges.isSafeCommit("HEAD"))
        #expect(!GitChanges.isSafeCommit("abc"))
    }
}

@Suite
struct GitInspectorTests {
    func git(_ repo: URL, _ args: String...) throws {
        let output = try ProcessRunner.runBlocking(
            executable: "/usr/bin/git", arguments: ["-C", repo.path] + args,
            environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"], currentDirectory: nil, timeout: 30
        )
.get()
        #expect(output.exitCode == 0, "git \(args): \(output.stderr)")
    }

    @Test
    func givenARealRepoWithChanges_whenComparedAgainstTheBaseline_thenFilesAndCountsMatch() async throws {
        // given
        let repo = try makeTempDir("pbm-git")
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "init", "-q", "-b", "main")
        try "a\nb\nc\n".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try "x\n".write(to: repo.appendingPathComponent("gone.txt"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        let base = try String(
            bytes: ProcessRunner.runBlocking(
                executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10
            )
.get()
.stdout,
            encoding: .utf8
        )!.trimmingCharacters(in: .whitespacesAndNewlines)

        try "a\nB\nc\nd\n".write(to: repo.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: repo.appendingPathComponent("gone.txt"))
        try "new\n".write(to: repo.appendingPathComponent("untracked file.txt"), atomically: true, encoding: .utf8)

        // when
        let inspector = GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
        let changes = await inspector.changes(repo: repo.path, baseCommit: base, startDirty: false)
        // then
        #expect(changes.branch == "main")
        #expect(changes.commitsSinceBase == 0)
        let byPath = Dictionary(uniqueKeysWithValues: changes.files.map { ($0.path, $0) })
        #expect(byPath["kept.txt"]?.status == "M")
        #expect(byPath["kept.txt"]?.added == 2)
        #expect(byPath["kept.txt"]?.removed == 1)
        #expect(byPath["gone.txt"]?.status == "D")
        #expect(byPath["untracked file.txt"]?.status == "?")
        #expect(Set(changes.diffs.map(\.path)) == ["kept.txt", "gone.txt"])
        #expect(changes.summaryLine.contains("3 files changed, +2 −2"), "\(changes.summaryLine)")
        #expect(changes.summaryLine.contains("Nothing committed"), "\(changes.summaryLine)")
    }

    func makeRepo() throws -> (URL, String) {
        let repo = try makeTempDir("pbm-git")
        try git(repo, "init", "-q", "-b", "main")
        try "a\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        try git(repo, "add", ".")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "base")
        let base = try String(
            bytes: ProcessRunner.runBlocking(
                executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10
            )
.get()
.stdout,
            encoding: .utf8
        )!.trimmingCharacters(in: .whitespacesAndNewlines)
        return (repo, base)
    }

    @Test
    func givenABaselineThatIsNotInTheRepo_whenCompared_thenTheFailureNeverReadsAsNoChanges() async throws {
        // given
        let (repo, _) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        let inspector = GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
        // when
        // A well-formed id that is not in this repo (another clone, or gc'd).
        let changes = await inspector.changes(repo: repo.path, baseCommit: "0123456789abcdef0123456789abcdef01234567", startDirty: false)
        // then
        #expect(!changes.comparedWithBase)
        #expect(!changes.failures.isEmpty)
        #expect(!changes.summaryLine.contains("No files changed"), "\(changes.summaryLine)")
        #expect(changes.summaryLine.contains("could not be compared"), "\(changes.summaryLine)")

        let gone = await inspector.changes(repo: repo.appendingPathComponent("missing").path, baseCommit: "0123456789abcdef", startDirty: false)
        #expect(!gone.comparedWithBase)
        #expect(!gone.summaryLine.contains("No files changed"), "\(gone.summaryLine)")
    }

    @Test
    func givenUserDiffPrefixSettings_whenComparing_thenPatchesStayAttachedToTheirFiles() async throws {
        // given
        let (repo, base) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "config", "diff.mnemonicPrefix", "true")
        try "b\n".write(to: repo.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
        // when
        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
            .changes(repo: repo.path, baseCommit: base, startDirty: false)
        // then
        #expect(changes.comparedWithBase)
        #expect(changes.files.map(\.path) == ["f.txt"])
        #expect(changes.diffs.map(\.path) == ["f.txt"], "the patch belongs to the listed file")
        try git(repo, "config", "diff.noprefix", "true")
        let noPrefix = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
            .changes(repo: repo.path, baseCommit: base, startDirty: false)
        #expect(noPrefix.diffs.map(\.path) == ["f.txt"])
    }

    @Test
    func givenNoBaselineCommit_whenComparing_thenUntrackedFilesAreStillListed() async throws {
        // given
        let repo = try makeTempDir("pbm-git")
        defer { try? FileManager.default.removeItem(at: repo) }
        try git(repo, "init", "-q")
        try "n\n".write(to: repo.appendingPathComponent("n.txt"), atomically: true, encoding: .utf8)
        // when
        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path]).changes(repo: repo.path, baseCommit: nil, startDirty: nil)
        // then
        #expect(changes.files.map(\.path) == ["n.txt"])
        #expect(changes.commitsSinceBase == nil)
        #expect(!changes.comparedWithBase)
        #expect(!changes.summaryLine.contains("No files changed"), "without a baseline tracked files were never compared")
        #expect(changes.labels.contains { $0.contains("No baseline commit") })
    }

    /// A task that can write the repo can plant a textconv or clean-filter driver in .git/config
    /// (plus .gitattributes) or a core.fsmonitor command. Opening Changes must run none of them.
    @Test
    func givenRepoConfiguredDriversAndHooks_whenComparing_thenNoneOfThemRun() async throws {
        // given
        let (repo, base) = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sentinels = try makeTempDir("pbm-sentinel")
        defer { try? FileManager.default.removeItem(at: sentinels) }
        func sentinel(_ name: String) -> String { sentinels.appendingPathComponent(name).path }
        try "d\n".write(to: repo.appendingPathComponent("g.dat"), atomically: true, encoding: .utf8)
        try git(repo, "add", "g.dat")
        try git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "dat")
        let base2 = try String(
            bytes: ProcessRunner.runBlocking(
                executable: "/usr/bin/git", arguments: ["-C", repo.path, "rev-parse", "HEAD"], environment: [:], currentDirectory: nil, timeout: 10
            )
.get()
.stdout,
            encoding: .utf8
        )!.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // when
        let changes = await GitInspector(environment: ["PATH": "/usr/bin:/bin", "HOME": repo.path, "GIT_CONFIG_NOSYSTEM": "1"])
            .changes(repo: repo.path, baseCommit: base2, startDirty: false)
        // then
        let fired = (try? FileManager.default.contentsOfDirectory(atPath: sentinels.path)) ?? []
        #expect(fired == [], "repo-configured commands ran: \(fired)")
        #expect(changes.comparedWithBase, "\(changes.failures)")
        #expect(Set(changes.diffs.map(\.path)) == ["f.txt", "g.dat"])
    }

    @Test
    func givenAMixedDriverListing_whenBuildingOverrides_thenOnlyRepoScopedDriversAreNeutralised() {
        // given
        let listing = Data(
            ("global\u{0}filter.lfs.clean\ngit-lfs clean -- %f\u{0}local\u{0}filter.evil.clean\ntouch x\u{0}"
                + "local\u{0}diff.a b.textconv\ncat\u{0}worktree\u{0}filter.w.process\nx\u{0}local\u{0}diff.bare.binary\u{0}").utf8
        )
        // when
        let overrides = GitInspector.driverOverrides(listing)
        // then
        #expect(overrides.contains("filter.evil.clean="))
        #expect(overrides.contains("filter.evil.process="))
        #expect(overrides.contains("filter.evil.required=false"))
        #expect(overrides.contains("diff.a b.textconv="))
        #expect(overrides.contains("diff.a b.command="))
        #expect(overrides.contains("filter.w.clean="))
        #expect(!overrides.contains { $0.hasPrefix("filter.lfs.") }, "the user's own global drivers are left alone")
    }

    @Test
    func givenAHostileRepoPath_whenBuildingArgv_thenNoShellIsInvolved() {
        // given / when
        let argv = GitInspector.argv(repo: "/r; rm -rf /", ["status"])
        // then
        #expect(Array(argv.prefix(2)) == ["-C", "/r; rm -rf /"])
        #expect(argv.last == "status")
        for pinned in ["core.fsmonitor=false", "core.hooksPath=/dev/null", "diff.external=", "core.quotepath=off"] {
            #expect(argv.contains(pinned), "\(pinned)")
        }
    }
}
