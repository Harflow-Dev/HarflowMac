import Foundation
@testable import MonitorCore
import Testing

@Suite struct UnsupportedEventEnvelopeTests {
    @Test @MainActor
    func givenAnUnstampedEvent_whenTailingStarts_thenAvailabilityIsUnavailableWithEnvelopeError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        FileManager.default.createFile(atPath: path, contents: Data((#"{"v":1,"seq":1,"kind":"notice"}"# + "\n").utf8))
        var seen: [EventAvailability] = []
        var history: EventHistoryState?
        let tailer = EventFileTailer(path: path, historyHandler: { history = $0 }) { _, _, availability in
            seen.append(availability)
        }
        tailer.start()
        defer { tailer.stop() }
        let reported = await waitUntil { seen.last == .unavailable }
        #expect(reported, "seen so far: \(seen)")
        #expect(history?.error == "The activity log could not be read.")
    }

    @Test @MainActor
    func givenAValidTail_whenAnUnstampedEventIsAppended_thenHistoryReportsEnvelopeError() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("t.events.jsonl").path
        let valid = #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":1,"kind":"notice"}"#
        FileManager.default.createFile(atPath: path, contents: Data((valid + "\n").utf8))
        var seen: [EventAvailability] = []
        var history: EventHistoryState?
        let tailer = EventFileTailer(path: path, historyHandler: { history = $0 }) { _, _, availability in
            seen.append(availability)
        }
        tailer.start()
        defer { tailer.stop() }
        let available = await waitUntil { seen.last == .available }
        #expect(available, "seen so far: \(seen)")
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? file.close() }
        try file.seekToEnd()
        try file.write(contentsOf: Data((#"{"v":1,"seq":2,"kind":"notice"}"# + "\n").utf8))
        let unavailable = await waitUntil { seen.last == .unavailable }
        #expect(unavailable, "seen so far: \(seen)")
        #expect(history?.error == "Unsupported Harflow event envelope")
    }
}
