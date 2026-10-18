import Foundation
@testable import MonitorCore
import Testing

// MARK: - MonitorMetricsTests

struct MonitorMetricsTests {
    @Test
    func givenParallelCounts_whenEncoded_thenOnlyNumericResidencyCounters() throws {
        // given
        let data = MonitorMetrics.encoded(stage: .parallelBuild, elapsedNanoseconds: 0, bytes: 0, peakRSSBytes: 0,
                                          residentColumns: 4, leasedMembers: 64, builtColumns: -1)
        // when
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // then
        #expect(record["resident_columns"] as? Int == 4)
        #expect(record["leased_members"] as? Int == 64)
        #expect(record["built_columns"] as? Int == 0)
        #expect(Set(record.keys) == ["monitor_metric_version", "stage", "duration_ms", "stdout_bytes", "stderr_bytes",
                                     "peak_rss_bytes", "monotonic_ns", "resident_columns", "leased_members", "built_columns"])
    }

    @Test
    func givenMeasurement_whenEncoded_thenOnlyFixedLabelsAndNumericMetadata() throws {
        // given
        let data = MonitorMetrics.encoded(stage: .decode, elapsedNanoseconds: 2_500_000, bytes: 128, peakRSSBytes: 4096)
        // when
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // then
        #expect(Set(record.keys) == ["monitor_metric_version", "stage", "duration_ms", "stdout_bytes", "stderr_bytes", "peak_rss_bytes", "monotonic_ns"])
        #expect(record["stage"] as? String == "decode")
        #expect(record["duration_ms"] as? Double == 2.5)
        #expect(record["stdout_bytes"] as? Int == 128)
        #expect(record["peak_rss_bytes"] as? Int == 4096)
        #expect(data.last == 0x0A)
    }

    @Test
    func givenInvalidCounts_whenEncoded_thenCountsAreNonnegative() throws {
        // given
        let data = MonitorMetrics.encoded(stage: .transport, elapsedNanoseconds: 0, bytes: -1, peakRSSBytes: -1)
        // when
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // then
        #expect(record["stdout_bytes"] as? Int == 0)
        #expect(record["peak_rss_bytes"] as? Int == 0)
    }

    @Test(arguments: [MonitorMetrics.Stage.sidebarPreparation, .sidebarScheduling, .sidebarBuild, .sidebarApply, .sidebarUpdateLatency])
    func givenSidebarStage_whenEncoded_thenFixedStageAndNumericCounters(stage: MonitorMetrics.Stage) throws {
        // given
        let data = MonitorMetrics.encoded(stage: stage, elapsedNanoseconds: 1_000_000, bytes: 0, peakRSSBytes: 0,
                                          renderingWrites: 3, backgroundThread: true)
        // when
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // then
        #expect(record["stage"] as? String == stage.rawValue)
        #expect(record["rendering_writes"] as? Int == 3)
        #expect(record["background_thread"] as? Int == 1)
        #expect(record.values.allSatisfy { $0 is NSNumber || $0 is String })
        #expect(Set(record.keys) == ["monitor_metric_version", "stage", "duration_ms", "stdout_bytes", "stderr_bytes",
                                     "peak_rss_bytes", "monotonic_ns", "rendering_writes", "background_thread"])
    }

    @Test
    func givenNoRenderingChanges_whenEncoded_thenZeroWritesAndMainThreadAreRepresented() throws {
        // given
        let data = MonitorMetrics.encoded(stage: .sidebarApply, elapsedNanoseconds: 0, bytes: 0, peakRSSBytes: 0,
                                          renderingWrites: -1, backgroundThread: false)
        // when
        let record = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        // then
        #expect(record["rendering_writes"] as? Int == 0)
        #expect(record["background_thread"] as? Int == 0)
    }
}
