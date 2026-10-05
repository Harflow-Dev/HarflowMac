import Foundation
@testable import MonitorCore
import Testing

@Suite struct EventPagingBenchmark {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PB_NATIVE_BENCHMARK"] == "1"))
    func givenLargeUniqueEditLog_whenPagingAndSummarizing_thenReportMeasuredWork() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let output = try FileHandle(forWritingTo: file)
        let padding = String(repeating: "x", count: 900)
        for batch in 0 ..< 1000 {
            let lines = (1 ... 100)
.map { index in
                let seq = batch * 100 + index
                return #"{"v":1,"seq":\#(seq),"kind":"tool_call","call_id":"\#(seq)","tool":"Edit","category":"edit", "#
                    + #""path":"/repo/\#(seq).swift","input_preview":"\#(padding)"}"#
            }
.joined(separator: "\n") + "\n"
            try output.write(contentsOf: Data(lines.utf8))
        }
        try output.close()
        var cursor: EventPageCursor?
        for index in 1 ... 3 {
            let start = Date()
            let page = try EventPages.read(path: file.path, before: cursor)
            let elapsed = Date().timeIntervalSince(start) * 1000
            print("NATIVE_ACTIVITY_PAGE page=\(index) events=\(page.events.count) bytes=\(page.bytesRead) milliseconds=\(elapsed)")
            #expect(page.events.count == 100)
            #expect(page.bytesRead <= EventPages.byteLimit + 448)
            cursor = page.next
        }
        var tail = LineTail(maxChunk: 64 << 10)
        tail.maxLines = 100
        var builder = EventSummaryBuilder()
        var batches = 0
        let start = Date()
        repeat {
            let read = tail.read(path: file.path)
            let step = try #require(read)
            builder.append(step.lines.compactMap(TaskEvent.init(line:)))
            #expect(step.lines.count <= 100)
            batches += 1
            if !step.more { break }
        } while true
        let elapsed = Date().timeIntervalSince(start) * 1000
        let summary = builder.summary
        print("NATIVE_ACTIVITY_SUMMARY records=\(summary.activity.toolCalls) files=\(summary.totalFiles) "
              + "publishedFiles=\(summary.files.count) batches=\(batches) milliseconds=\(elapsed)")
        #expect(summary.activity.toolCalls == 100_000)
        #expect(summary.totalFiles == 100_000)
        #expect(summary.files.count == 100)
        #expect(builder.snapshot(fileLimit: 200).files.count == 200)
    }
}
