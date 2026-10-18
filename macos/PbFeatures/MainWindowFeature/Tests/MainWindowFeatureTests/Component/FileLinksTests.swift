import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - FileLinksTests

@Suite struct FileLinksTests {

    private static let existing: Set<String> = [
        "/repo", "/repo/README.md", "/repo/Sources/App.swift", "/tmp/notes.md", "/repo/review.command",
        "/repo/Tool.app", "/repo/run", "/repo/report.html", "/repo/Review.app", "/repo/Review.app/check.command",
        "/repo/link.md", "/repo/LICENSE", "/repo/Sources", "/tmp"
    ]
    private static let directories: Set<String> = ["/repo", "/repo/Tool.app", "/repo/Review.app", "/repo/Sources", "/tmp"]
    private static let packages: Set<String> = ["/repo/Tool.app", "/repo/Review.app"]
    private static let executables: Set<String> = ["/repo/run"]
    private let probe = FileLinks.Probe(
        exists: { existing.contains($0) },
        resolved: { $0 == "/repo/link.md" ? "/repo/review.command" : $0 },
        isExecutable: { executables.contains($0) },
        isPackage: { packages.contains($0) },
        isDirectory: { directories.contains($0) }
    )

    private func target(_ string: String, repoPath: String? = "/repo") -> FileLinks.Target {
        FileLinks.target(for: URL(string: string)!, repoPath: repoPath, probe: probe)
    }

    @Test func givenAWebOrMailLink_whenResolving_thenItOpensUnchanged() {
        // given / when / then
        #expect(target("https://example.com/docs") == .open(URL(string: "https://example.com/docs")!))
        #expect(target("mailto:someone@example.com") == .open(URL(string: "mailto:someone@example.com")!))
    }

    @Test func givenAnyOtherScheme_whenResolving_thenItIsDropped() {
        // given / when / then — a custom scheme could launch an app.
        #expect(target("x-apple.systempreferences:com.apple.preference.security") == .discard)
        #expect(target("vscode://file/repo/README.md") == .discard)
    }

    @Test func givenARelativePath_whenResolving_thenItOpensInsideTheRepository() {
        // given / when / then
        #expect(target("./Sources/App.swift") == .open(URL(fileURLWithPath: "/repo/Sources/App.swift")))
    }

    @Test func givenARootLevelNameWithALineSuffix_whenResolving_thenItOpensTheFileNotAScheme() {
        // given / when / then — "README.md:12" parses as a URL with scheme "README.md".
        #expect(target("README.md:12") == .open(URL(fileURLWithPath: "/repo/README.md")))
        #expect(FileLinks.link(forPath: "README.md:12") == URL(string: "./README.md:12"))
    }

    @Test func givenLineSuffixes_whenResolving_thenTheyAreDroppedBeforeLookingTheFileUp() {
        // given / when / then
        #expect(target("./Sources/App.swift:149:3") == .open(URL(fileURLWithPath: "/repo/Sources/App.swift")))
        #expect(target("./Sources/App.swift#L10-L20") == .open(URL(fileURLWithPath: "/repo/Sources/App.swift")))
    }

    @Test func givenAFileSchemeOrAbsolutePath_whenResolving_thenItOpens() {
        // given / when / then
        #expect(target("file:///repo/README.md", repoPath: nil) == .open(URL(fileURLWithPath: "/repo/README.md")))
        #expect(target("/tmp/notes.md", repoPath: nil) == .open(URL(fileURLWithPath: "/tmp/notes.md")))
    }

    @Test func givenARunnableItem_whenResolving_thenOnlyItsFolderOpens() {
        // given / when / then — an agent-written .command, an app bundle or an executable never runs.
        let folder = URL(fileURLWithPath: "/repo", isDirectory: true)
        #expect(target("./review.command") == .open(folder))
        #expect(target("./Tool.app") == .open(folder))
        #expect(target("./run") == .open(folder))
    }

    @Test func givenAScriptInsideABundle_whenResolving_thenTheBundleIsSkippedForTheFolderAboveIt() {
        // given / when / then — "open the parent" must never land on Review.app itself.
        #expect(target("./Review.app/check.command") == .open(URL(fileURLWithPath: "/repo", isDirectory: true)))
    }

    @Test func givenAnActiveDocumentType_whenResolving_thenOnlyItsFolderOpens() {
        // given / when / then — local HTML would run its JavaScript in the browser.
        #expect(target("./report.html") == .open(URL(fileURLWithPath: "/repo", isDirectory: true)))
    }

    @Test func givenASymlinkToARunnableFile_whenResolving_thenItIsJudgedByItsTarget() {
        // given / when / then — link.md points at review.command.
        #expect(target("./link.md") == .open(URL(fileURLWithPath: "/repo", isDirectory: true)))
    }

    @Test func givenAPlainFileWithNoExtension_whenResolving_thenItOpens() {
        // given / when / then
        #expect(target("./LICENSE") == .open(URL(fileURLWithPath: "/repo/LICENSE")))
    }

    @Test func givenAPathThatDoesNotExistOrCannotBeResolved_whenResolving_thenItIsDropped() {
        // given / when / then
        #expect(target("./Missing.swift") == .discard)
        #expect(target("./Sources/App.swift", repoPath: nil) == .discard)
        #expect(target("file:///nowhere.md") == .discard)
    }

    @Test func givenTheRealProbe_whenAskingAboutAnExecutableScript_thenItIsNotAPassiveDocument() {
        // given
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pb-link-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: url.path, contents: Data("echo hi".utf8), attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: url) }

        // when / then — a .txt with the executable bit set still doesn't count as a document.
        #expect(!FileLinks.isPassiveDocument(url.path, probe: .live))
    }
}
