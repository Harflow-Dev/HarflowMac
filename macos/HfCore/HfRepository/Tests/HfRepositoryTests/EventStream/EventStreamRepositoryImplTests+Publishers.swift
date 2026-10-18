import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

extension EventStreamRepositoryImplTests {
    @Test func givenLoadedSummary_whenRepeatedPagingAddsNoContent_thenOnlyActualSummaryChangesPublish() async throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("publisher.events.jsonl")
        let initial = currentEventFixture(#"{"v":1,"seq":1,"kind":"task_started","prompt":"hello","backend":"claude"}"#)
        try (initial + "\n").write(to: path, atomically: true, encoding: .utf8)
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(directory.path)
        let snapshots = MockTaskSnapshotRepository()
        let scheduler = MockScheduling()
        let sut = EventStreamRepositoryImpl(
            toolEnvironment: environment,
            snapshotRepository: snapshots,
            scheduler: scheduler,
            compatibilityCheck: { _ in .success(()) }
        )
        let lease = sut.acquireSummary("publisher")
        defer { lease.release() }
        await waitUntil { sut.summary(for: "publisher").availability == .available }
        let summaries = LockedBox<[EventSummary]>([])
        let subscription = sut.summaryPublisher(for: "publisher").sink { value in summaries.mutate { $0.append(value) } }
        defer { subscription.cancel() }
        // when: these requests enqueue real, equal summary assignments on the serial summary queue.
        sut.loadMoreSummaryFiles("publisher")
        sut.loadMoreSummaryFiles("publisher")
        let edit = currentEventFixture(
            #"{"v":1,"seq":2,"kind":"tool_call","call_id":"edit","tool":"Edit","category":"edit","path":"a.swift","input_preview":""}"#
        )
        let file = try FileHandle(forWritingTo: path)
        try file.seekToEnd()
        try file.write(contentsOf: Data((edit + "\n").utf8))
        try file.close()
        await waitUntil { sut.summary(for: "publisher").activity.edits == 1 }
        // then: the later serial read proves the earlier no-op paging assignments were processed.
        #expect(summaries.value.count == 2)
        #expect(summaries.value.first?.prompt == "hello")
        #expect(summaries.value.last?.activity.edits == 1)
        #expect(summaries.value.last?.files.map(\.path) == ["a.swift"])
    }
}
