import Combine
import Darwin
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

@Suite struct ActivityRepositoryBenchmarkTests {
    /// Opt-in synthetic file benchmark. Settlement includes the test observer's 50 ms polling floor.
    @Test func benchmarkActivityRepository() async throws {
        guard let output = ProcessInfo.processInfo.environment["PB_ACTIVITY_REPOSITORY_BENCHMARK_OUTPUT"] else { return }
        var observations: [[String: Any]] = []
        for conversationCount in [8, 64, 256] {
            for sample in 0 ..< 10 {
                observations += try await measure(conversationCount: conversationCount, sample: sample)
            }
        }
        let metricsPath = try #require(ProcessInfo.processInfo.environment["PB_ACTIVITY_REPOSITORY_METRICS_PATH"])
        let metricText = try String(contentsOfFile: metricsPath, encoding: .utf8)
        let metrics: [[String: Any]] = metricText.split(separator: "\n").compactMap { line in
            guard let data = String(line).data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stage = value["stage"] as? String, ["activityFold", "activityPageRead"].contains(stage) else { return nil }
            return value
        }
        #expect(!metrics.isEmpty)
        #expect(metrics.allSatisfy { ($0["background_thread"] as? Int) == 1 })
        let document: [String: Any] = [
            "benchmark_version": 1,
            "measurement_boundary": "real synthetic file reads and repository settlement; observer polling floor; no UI latency",
            "resident_members": 16,
            "offscreen_inventory": "logical group sizes do not instantiate offscreen streams",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "configuration": "debug Swift test; summary readers and live tails active; process RSS includes test runner",
            "observations": observations,
            "internal_stage_metrics": metrics
        ]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    private func measure(conversationCount: Int, sample: Int) async throws -> [[String: Any]] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ids = (0 ..< 16).map { "benchmark-\($0)" }
        let text = (1 ... 516).map { eventLine($0) }.joined(separator: "\n") + "\n"
        for id in ids { try text.write(to: directory.appendingPathComponent("\(id).events.jsonl"), atomically: true, encoding: .utf8) }
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(directory.path)
        let repository = EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: NullTaskSnapshotRepository(), scheduler: NullScheduling())
        var leases: [any EventStreamLease] = []
        defer { leases.forEach { $0.release() } }
        var records: [[String: Any]] = []
        var start = DispatchTime.now().uptimeNanoseconds
        leases = ids.map { repository.acquire($0) }
        await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).count == 100 && !repository.history(for: $0).isLoading } }
        #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array(417 ... 516) })
        records.append(record("initial_seed", start, conversationCount, sample, repository))
        for page in 1 ... 2 {
            start = DispatchTime.now().uptimeNanoseconds
            ids.forEach { repository.loadMore($0) }
            await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).count == 100 * (page + 1) && !repository.history(for: $0).isLoading } }
            #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array((417 - page * 100) ... 516) })
            records.append(record(page == 1 ? "older_page" : "prepend_rebuild", start, conversationCount, sample, repository))
        }
        let publications = LockedBox(0)
        let subscriptions = ids.map { id in
            repository.itemsPublisher(for: id).dropFirst().sink { _ in publications.mutate { $0 += 1 } }
        }
        defer { subscriptions.forEach { $0.cancel() } }
        start = DispatchTime.now().uptimeNanoseconds
        for id in ids {
            let handle = try FileHandle(forWritingTo: directory.appendingPathComponent("\(id).events.jsonl"))
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(((517 ... 548).map { eventLine($0) }.joined(separator: "\n") + "\n").utf8))
            try handle.close()
        }
        await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).last?.seq == 548 } && publications.value >= 16 }
        #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array(217 ... 548) })
        records.append(record("live_event_burst", start, conversationCount, sample, repository, publications: publications.value))
        let before = publications.value
        start = DispatchTime.now().uptimeNanoseconds
        // A negative publication observation must cover the tailer's actual one-second poll.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(publications.value == before)
        records.append(record("unchanged_poll", start, conversationCount, sample, repository, publications: publications.value - before))
        return records
    }

    private func eventLine(_ seq: Int) -> String {
        #"{"v":1,"seq":\#(seq),"kind":"assistant_text","text":"synthetic activity row"}"#
    }

    private func record(_ scenario: String, _ start: UInt64, _ conversations: Int, _ sample: Int,
                        _ repository: EventStreamRepositoryImpl, publications: Int? = nil) -> [String: Any] {
        let end = DispatchTime.now().uptimeNanoseconds
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        var value: [String: Any] = ["scenario": scenario, "conversations": conversations, "chain_turns": 16, "sample": sample,
                "start_ns": start, "end_ns": end, "settlement_ms": Double(end - start) / 1_000_000,
                "leased_members": repository.leasedTaskIDs.count, "peak_process_rss_bytes": usage.ru_maxrss]
        if let publications { value["presentation_publications"] = publications }
        return value
    }
}
