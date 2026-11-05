import Combine
import Darwin
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import os
import Testing

// MARK: - ActivityRepositoryBenchmarkTests

@Suite struct ActivityRepositoryBenchmarkTests {
    /// Opt-in bounded public-page decoding, projection and publisher-settlement benchmark.
    @Test func benchmarkActivityRepository() async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_ACTIVITY_REPOSITORY_BENCHMARK_OUTPUT"] else { return }
        var observations: [[String: Any]] = []
        for conversationCount in [8, 64, 256] {
            for sample in 0 ..< 10 {
                observations += await measure(conversationCount: conversationCount, sample: sample)
            }
        }
        let document: [String: Any] = [
            "benchmark_version": 2,
            "measurement_boundary": "synthetic public pages, production projection and publisher settlement; no engine process or UI latency",
            "resident_members": 16,
            "offscreen_inventory": "logical group sizes do not instantiate offscreen streams",
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "processor_count": ProcessInfo.processInfo.processorCount,
            "configuration": "debug Swift test; public activity and summary sessions active; process RSS includes test runner",
            "observations": observations
        ]
        try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output))
    }

    private func measure(conversationCount: Int, sample: Int) async -> [[String: Any]] {
        let ids = (0 ..< 16).map { "benchmark-\($0)" }
        let reader = BenchmarkPublicPageReader()
        let ticks = LockedBox<[@Sendable () -> Void]>([])
        let scheduler = MockScheduling()
        given(scheduler).scheduleRepeating(every: .any, execute: .any).willProduce { _, callback in
            ticks.mutate { $0.append(callback) }
            return AnyCancellable {}
        }
        let repository = EventStreamRepositoryImpl(snapshotRepository: NullTaskSnapshotRepository(), scheduler: scheduler,
            reader: reader, promptRepository: NullTaskPromptRepository(), delivery: { $0() })
        var leases: [any EventStreamLease] = []
        defer { leases.forEach { $0.release() } }
        var records: [[String: Any]] = []
        var start = DispatchTime.now().uptimeNanoseconds
        leases = ids.map { repository.acquire($0) }
        await waitUntil(timeout: 10) {
            ids.allSatisfy { repository.events(for: $0).count == 100 && repository.observation(for: $0).summary.state == .observed }
        }
        #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array(417 ... 516) })
        records.append(record("initial_seed", start, (conversationCount, sample), repository, reader))
        for page in 1 ... 2 {
            start = DispatchTime.now().uptimeNanoseconds
            ids.forEach { repository.loadMore($0) }
            await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).count == 100 * (page + 1) && !repository.history(for: $0).isLoading } }
            #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array((417 - page * 100) ... 516) })
            records.append(record(page == 1 ? "older_page" : "prepend_rebuild", start, (conversationCount, sample), repository, reader))
        }
        let publications = LockedBox(0)
        let subscriptions = ids.map { id in
            repository.itemsPublisher(for: id).sink { _ in publications.mutate { $0 += 1 } }
        }
        defer { subscriptions.forEach { $0.cancel() } }
        await waitUntil { publications.value == 16 }
        let beforeBurst = publications.value
        start = DispatchTime.now().uptimeNanoseconds
        reader.appendBurst()
        ticks.value.forEach { $0() }
        await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).last?.seq == 548 } && publications.value >= beforeBurst + 16 }
        #expect(ids.allSatisfy { repository.events(for: $0).map(\.seq) == Array(217 ... 548) })
        records.append(record("live_event_burst", start, (conversationCount, sample), repository, reader, publications: publications.value - beforeBurst))
        let before = publications.value
        let reads = reader.reads
        start = DispatchTime.now().uptimeNanoseconds
        ticks.value.forEach { $0() }
        await waitUntil(timeout: 10) { reader.reads >= reads + 32 }
        // A subsequent changed public page provides a serial processing/publication barrier.
        reader.appendOne()
        ticks.value.forEach { $0() }
        await waitUntil(timeout: 10) { ids.allSatisfy { repository.events(for: $0).last?.seq == 549 } && publications.value >= before + 16 }
        #expect(publications.value == before + 16)
        #expect(reader.allReadsOffMain)
        records.append(record("unchanged_poll_then_changed_barrier", start, (conversationCount, sample), repository, reader,
            publications: publications.value - before - 16))
        return records
    }

    private func record(_ scenario: String, _ start: UInt64, _ sample: (conversations: Int, index: Int),
                        _ repository: EventStreamRepositoryImpl, _ reader: BenchmarkPublicPageReader, publications: Int? = nil) -> [String: Any] {
        let end = DispatchTime.now().uptimeNanoseconds
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        var value: [String: Any] = ["scenario": scenario, "conversations": sample.conversations, "chain_turns": 16, "sample": sample.index,
            "start_ns": start, "end_ns": end, "settlement_ms": Double(end - start) / 1_000_000,
            "leased_members": repository.leasedTaskIDs.count, "peak_process_rss_bytes": usage.ru_maxrss,
            "public_page_reads": reader.reads, "public_reads_off_main": reader.allReadsOffMain]
        if let publications { value["presentation_publications"] = publications }
        return value
    }
}

// MARK: - BenchmarkPublicPageReader

private final class BenchmarkPublicPageReader: PublicEventObservationReader, Sendable {
    private struct State: Sendable { var end = 516; var reads = 0; var offMain = true }
    private let state = OSAllocatedUnfairLock(initialState: State())
    var reads: Int { state.withLock { $0.reads } }
    var allReadsOffMain: Bool { state.withLock { $0.offMain } }
    func appendBurst() { state.withLock { $0.end = 548 } }
    func appendOne() { state.withLock { $0.end = 549 } }

    func read(taskID _: String, position: TaskEventPagePosition,
              operationIsCurrent: @escaping @Sendable () -> Bool) async -> Result<TaskEventPage, ToolError> {
        guard operationIsCurrent() else { return .failure(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "cancelled")) }
        let end = state.withLock { value in
            value.reads += 1
            value.offMain = value.offMain && !Thread.isMainThread
            return value.end
        }
        let lower: Int
        let upper: Int
        switch position {
        case .newest: lower = max(1, end - 99); upper = end
        case .oldest: lower = 1; upper = min(end, 100)
        case .cursor(let cursor):
            let boundary = Int(cursor.split(separator: "-").last ?? "0") ?? 0
            if cursor.hasPrefix("before-") { lower = max(1, boundary - 100); upper = boundary - 1 } else {
                lower = boundary + 1; upper = min(end, boundary + 100)
            }
        }
        let events = lower <= upper ? (lower ... upper).map { ObservationFixtures.record($0) } : []
        return .success(ObservationFixtures.page(events, older: lower > 1 ? "before-\(lower)" : nil,
            newer: "after-\(max(upper, lower - 1))", more: upper < end))
    }
}
