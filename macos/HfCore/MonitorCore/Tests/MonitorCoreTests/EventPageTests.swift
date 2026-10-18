import Foundation
@testable import MonitorCore
import Testing

@Suite struct EventPageTests {
    private func fixture(_ count: Int) throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let text = (1 ... count)
.map { seq in
            #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":\#(seq),"kind":"assistant_text","text":"row"}"#
        }
.joined(separator: "\n") + "\n"
        try text.write(to: path, atomically: true, encoding: .utf8)
        return path
    }

    @Test func givenThreePages_whenReadBackward_thenEachEventAppearsOnce() throws {
        let file = try fixture(250)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try EventPages.read(path: file.path)
        let second = try EventPages.read(path: file.path, before: first.next)
        let third = try EventPages.read(path: file.path, before: second.next)
        #expect(first.events.map(\.seq) == Array(151 ... 250))
        #expect(second.events.map(\.seq) == Array(51 ... 150))
        #expect(third.events.map(\.seq) == Array(1 ... 50))
        #expect(third.next == nil)
        #expect(first.bytesRead <= EventPages.byteLimit + 384)
        var tail = LineTail()
        tail.seed(first.end)
        #expect(tail.read(path: file.path)?.lines.isEmpty == true)
    }

    @Test func givenReplacedFile_whenLoadingOlder_thenCursorRejectsNewGeneration() throws {
        let file = try fixture(150)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try EventPages.read(path: file.path)
        try "replacement\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: EventPageError.self) { try EventPages.read(path: file.path, before: first.next) }
    }

    @Test func givenSameInodeRegrowthAboveOlderOffset_whenPaging_thenSnapshotRejectsRewrite() throws {
        let file = try fixture(250)
        defer { try? FileManager.default.removeItem(at: file) }
        let first = try EventPages.read(path: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seek(toOffset: first.end.offset - 16)
        try handle.write(contentsOf: Data(repeating: 32, count: 16))
        #expect(throws: EventPageError.self) { try EventPages.read(path: file.path, before: first.next) }
    }

    @Test func givenUnstampedEvent_whenPaging_thenThePageIsUnavailable() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try (#"{"v":1,"seq":1,"kind":"notice"}"# + "\n")
            .write(to: file, atomically: true, encoding: .utf8)
        do {
            _ = try EventPages.read(path: file.path)
            Issue.record("unstamped event should make the page unavailable")
        } catch let error as EventPageError {
            if case .unavailable = error {} else { Issue.record("expected unavailable, got \(error)") }
        }
    }

    @Test func givenSmallByteBudget_whenPaging_thenPartialBoundaryDoesNotLoseCompleteEvents() throws {
        let file = try fixture(150)
        defer { try? FileManager.default.removeItem(at: file) }
        var cursor: EventPageCursor?
        var values: [Int] = []
        repeat {
            let page = try EventPages.read(path: file.path, before: cursor, byteLimit: 1024)
            values = page.events.map(\.seq) + values
            cursor = page.next
            #expect(page.bytesRead <= 1024 + 448)
        } while cursor != nil
        #expect(values == Array(1 ... 150))
    }
}
