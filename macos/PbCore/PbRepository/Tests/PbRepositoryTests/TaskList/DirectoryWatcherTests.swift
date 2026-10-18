import Foundation
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct DirectoryWatcherTests {

    @Test func givenAMissingFolder_whenStarted_thenTheWatcherDoesNotAttach() {
        // given — F4-28
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-missing-\(UUID().uuidString)").path
        let sut = DirectoryWatcher(path: missing) { _ in }

        // when
        sut.start()

        // then
        #expect(sut.isActive == false)
    }

    @Test func givenAnExistingFolder_whenStarted_thenTheWatcherBecomesActive() {
        // given
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sut = DirectoryWatcher(path: dir.path) { _ in }

        // when
        sut.start()

        // then
        #expect(sut.isActive == true)
    }

    @Test func givenAFileWrittenInTheWatchedFolder_whenObserved_thenTheHandlerReportsItsName() async {
        // given
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("PbRepoTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let seenNames = LockedBox<[String]>([])
        let sut = DirectoryWatcher(path: dir.path) { names in
            seenNames.mutate { $0.append(contentsOf: names) }
        }
        sut.start()

        // when
        try? "hello".write(to: dir.appendingPathComponent("abc.meta.json"), atomically: true, encoding: .utf8)

        // then
        await waitUntil(timeout: 5) { seenNames.value.contains("abc.meta.json") }
    }
}
