import AppKit
import Darwin
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

/// Opt-in hosted resource measurement: synthetic input only, with no engine or user-state access.
@MainActor @Suite(.serialized) struct ActivityFeedIssue34SoakTests {
    @Test func givenLongRetainedFeed_whenStreamingForMinutes_thenNativeResourcesPlateauAndIdleWorkStops() async throws {
        guard let configured = ProcessInfo.processInfo.environment["HARFLOW_ACTIVITY_SOAK_SECONDS"],
              let seconds = Double(configured), seconds.isFinite, seconds >= 120 else { return }
        // given
        _ = NSApplication.shared
        var rows = (0 ..< 3000).map { index in
            ActivityRow.single(ActivityFixture.text(index, "Synthetic retained message \(index). Selectable reading content.", task: "soak"))
        }
        var snapshot = ActivityFeedSnapshot.preparing(rows, previous: nil)
        let state = ParallelColumnUIState()
        state.retainedFirstID = rows.first?.id
        let host = NSHostingView(rootView: feed(rows, snapshot: snapshot, state: state))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 30) { state.viewportPositioned }
        try #require(state.viewportPositioned)
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let owner = try #require(table.owner)
        let scroll = try #require(table.enclosingScrollView)
        try #require(owner.boxes.count >= 3000)
        for index in stride(from: 0, to: 3000, by: 50) {
            table.scrollRowToVisible(index)
            host.layoutSubtreeIfNeeded()
            await Task.yield()
        }
        activityNativeRevealBottom(scroll)
        await waitUntil(timeout: 5) { state.followLive.isFollowing }
        try #require(state.followLive.isFollowing)
        await observe(for: 2)
        let started = Date()
        var samples = [try resourceSample(since: started, hosts: owner.cells.count)]
        var tick = 0
        var nextSample = started.addingTimeInterval(5)
        var maximumHosts = owner.cells.count
        // when: bounded text changes at 5 Hz; retained history and row identities stay fixed.
        while Date().timeIntervalSince(started) < seconds {
            let due = Date().addingTimeInterval(0.2)
            rows[rows.count - 1] = .single(ActivityFixture.text(2999,
                "Synthetic streaming delta \(tick % 100). " + String(repeating: "bounded text ", count: tick % 8 + 1),
                task: "soak", streaming: true))
            snapshot = ActivityFeedSnapshot.preparing(rows, previous: snapshot)
            host.rootView = feed(rows, snapshot: snapshot, state: state)
            let expected = snapshot
            await waitUntil(timeout: 5) { owner.model?.activitySnapshot === expected }
            try #require(owner.model?.activitySnapshot === expected, "The streamed snapshot must actually commit")
            maximumHosts = max(maximumHosts, owner.cells.count)
            if Date() >= nextSample {
                samples.append(try resourceSample(since: started, hosts: owner.cells.count))
                nextSample = Date().addingTimeInterval(5)
            }
            tick += 1
            await waitUntil(timeout: 0.3) { Date() >= due }
        }
        samples.append(try resourceSample(since: started, hosts: owner.cells.count))
        // then: broad allocator tolerance catches runaway growth without treating RSS jitter as a leak.
        assertResourcePlateau(samples, maximumHosts: maximumHosts)
        let idleCPU = try await finishAndAssertIdle(host: host, owner: owner, started: started)
        print("HARFLOW_ACTIVITY_SOAK seconds=\(seconds) ticks=\(tick) idle_cpu_cores=\(idleCPU)")
    }

    private func assertResourcePlateau(_ samples: [ActivitySoakResourceSample], maximumHosts: Int) {
        let early = Array(samples.prefix(max(1, samples.count / 3)))
        let late = Array(samples.suffix(max(1, samples.count / 3)))
        let rssGrowth = median(late.map(\.rss)) - median(early.map(\.rss))
        let footprintGrowth = median(late.map(\.footprint)) - median(early.map(\.footprint))
        #expect(rssGrowth < 256 * 1024 * 1024)
        #expect(footprintGrowth < 256 * 1024 * 1024)
        #expect(maximumHosts <= 64, "Native hosting residency must stay bounded by the small viewport")
        let earlyCPU = cpuRate(early)
        let lateCPU = cpuRate(late)
        #expect(lateCPU <= earlyCPU * 1.75 + 0.15, "Streaming CPU must not grow with elapsed session time")
        print("HARFLOW_ACTIVITY_SOAK maximum_hosts=\(maximumHosts) rss_growth_bytes=\(rssGrowth) "
              + "footprint_growth_bytes=\(footprintGrowth) early_cpu_cores=\(earlyCPU) late_cpu_cores=\(lateCPU)")
        for sample in samples {
            print("HARFLOW_ACTIVITY_SOAK_SAMPLE elapsed=\(sample.elapsed) cpu_seconds=\(sample.cpu) "
                  + "rss_bytes=\(sample.rss) footprint_bytes=\(sample.footprint) hosts=\(sample.hosts)")
        }
    }

    private func finishAndAssertIdle(host: NSHostingView<ActivityFeedView>, owner: ActivityFeedNativeList.Coordinator,
                                     started: Date) async throws -> Double {
        var rows = try #require(owner.model?.shownRows)
        let state = try #require(owner.state)
        rows[rows.count - 1] = .single(ActivityFixture.text(2999, "Synthetic stream finished.", task: "soak"))
        let snapshot = ActivityFeedSnapshot.preparing(rows, previous: owner.model?.activitySnapshot)
        host.rootView = feed(rows, snapshot: snapshot, state: state)
        await waitUntil(timeout: 5) { owner.model?.activitySnapshot === snapshot }
        try #require(owner.model?.activitySnapshot === snapshot)
        await observe(for: 2)
        let counters = (owner.reconcileCount, owner.measurementCount, owner.rootRefreshCount)
        let idleStart = try resourceSample(since: started, hosts: owner.cells.count)
        await observe(for: 5)
        let idleEnd = try resourceSample(since: started, hosts: owner.cells.count)
        #expect(owner.reconcileCount == counters.0)
        #expect(owner.measurementCount == counters.1)
        #expect(owner.rootRefreshCount == counters.2)
        let idleCPU = cpuRate([idleStart, idleEnd])
        #expect(idleCPU < 0.35, "A settled non-streaming feed must leave the process substantially idle")
        return idleCPU
    }

    private func feed(_ rows: [ActivityRow], snapshot: ActivityFeedSnapshot, state: ParallelColumnUIState) -> ActivityFeedView {
        ActivityFeedView(rows: rows, activitySnapshot: snapshot, start: nil, history: EventHistoryState(),
                         isLoading: false, state: state, onLoadMore: nil)
    }

    private func observe(for seconds: TimeInterval) async {
        let deadline = Date().addingTimeInterval(seconds)
        await waitUntil(timeout: seconds + 1) { Date() >= deadline }
    }

    private func resourceSample(since started: Date, hosts: Int) throws -> ActivitySoakResourceSample {
        var usage = rusage()
        try #require(getrusage(RUSAGE_SELF, &usage) == 0)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        try #require(result == KERN_SUCCESS)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        return ActivitySoakResourceSample(elapsed: Date().timeIntervalSince(started), cpu: cpu,
                                          rss: Double(info.resident_size), footprint: Double(info.phys_footprint), hosts: hosts)
    }

    private func median(_ values: [Double]) -> Double { values.sorted()[values.count / 2] }

    private func cpuRate(_ samples: [ActivitySoakResourceSample]) -> Double {
        guard let first = samples.first, let last = samples.last, last.elapsed > first.elapsed else { return 0 }
        return (last.cpu - first.cpu) / (last.elapsed - first.elapsed)
    }
}

private struct ActivitySoakResourceSample {
    let elapsed: Double
    let cpu: Double
    let rss: Double
    let footprint: Double
    let hosts: Int
}
