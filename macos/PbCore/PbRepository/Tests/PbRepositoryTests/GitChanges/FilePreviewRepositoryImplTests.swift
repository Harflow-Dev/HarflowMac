import Foundation
@testable import PbRepository
import Testing

@Suite struct FilePreviewRepositoryImplTests {

    private func tempRepo() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func givenAnUnreadableUntrackedFile_whenPreviewed_thenItReportsUnreadable() async {
        // given
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let sut = FilePreviewRepositoryImpl()

        // when
        let result = await sut.preview(repo: repo.path, path: "does-not-exist.txt")

        // then
        #expect(result == .unreadable)
    }

    @Test func givenABinaryUntrackedFile_whenPreviewed_thenItReportsBinary() async {
        // given
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = repo.appendingPathComponent("binary.dat")
        try? Data([0x41, 0x42, 0x00, 0x43]).write(to: path)
        let sut = FilePreviewRepositoryImpl()

        // when
        let result = await sut.preview(repo: repo.path, path: "binary.dat")

        // then
        #expect(result == .binary)
    }

    @Test func givenATextUntrackedFileOver64KiB_whenPreviewed_thenOnlyTheFirst64KiBIsRead() async {
        // given
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = repo.appendingPathComponent("large.txt")
        let content = String(repeating: "a", count: FilePreviewRepositoryImpl.maxBytes + 1000)
        try? content.write(to: path, atomically: true, encoding: .utf8)
        let sut = FilePreviewRepositoryImpl()

        // when
        let result = await sut.preview(repo: repo.path, path: "large.txt")

        // then
        guard case .text(let text) = result else {
            Issue.record("expected .text")
            return
        }
        #expect(text.utf8.count == FilePreviewRepositoryImpl.maxBytes)
    }

    @Test func givenASmallTextFile_whenPreviewed_thenTheWholeContentsReturn() async {
        // given
        let repo = tempRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let path = repo.appendingPathComponent("small.txt")
        try? "hello world".write(to: path, atomically: true, encoding: .utf8)
        let sut = FilePreviewRepositoryImpl()

        // when
        let result = await sut.preview(repo: repo.path, path: "small.txt")

        // then
        #expect(result == .text("hello world"))
    }
}
