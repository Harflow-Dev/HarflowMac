import Combine
import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

struct EventSummaryRetryTests {
    private func makeSUT(directory: URL) -> EventStreamRepositoryImpl {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(directory.path)
        return EventStreamRepositoryImpl(toolEnvironment: environment, snapshotRepository: NullTaskSnapshotRepository(), scheduler: NullScheduling())
    }

    private func edit(_ seq: Int, path: String) -> String {
        #"{"v":1,"seq":\#(seq),"kind":"tool_call","call_id":"\#(seq)","tool":"Edit","category":"edit","path":"\#(path)"}"# + "\n"
    }

    @Test(.timeLimit(.minutes(1)))
    func givenSummaryLeaseBeforeFileCreation_whenFileAppears_thenBoundedRetryLoadsCumulativeSummary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = makeSUT(directory: directory)
        let lease = sut.acquireSummary("late")
        defer { lease.release() }
        await waitUntil { sut.summary(for: "late").availability == .unavailable }
        #expect(sut.events(for: "late").isEmpty)
        try (1 ... 250)
.map { edit($0, path: "file\($0).swift") }
.joined()
            .write(to: directory.appendingPathComponent("late.events.jsonl"), atomically: true, encoding: .utf8)
        await waitUntil(timeout: 5) { sut.summary(for: "late").availability == .available }
        let summary = sut.summary(for: "late")
        #expect(summary.activity.edits == 250)
        #expect(summary.totalFiles == 250)
        #expect(summary.files.count == 100)
        #expect(sut.events(for: "late").isEmpty)
        #expect(sut.leasedTaskIDs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func givenTemporarilyMissingFile_whenSameFileReturns_thenRetryRetainsProjectionAndDoesNotReplayConsumedEvents() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("retry.events.jsonl")
        let hidden = directory.appendingPathComponent("hidden")
        try (1 ... 150)
.map { edit($0, path: "file\($0).swift") }
.joined()
            .write(to: path, atomically: true, encoding: .utf8)
        let sut = makeSUT(directory: directory)
        let lease = sut.acquireSummary("retry")
        defer { lease.release() }
        await waitUntil { sut.summary(for: "retry").availability == .available }
        sut.loadMoreSummaryFiles("retry")
        await waitUntil { sut.summary(for: "retry").files.count == 150 }
        try FileManager.default.moveItem(at: path, to: hidden)
        await waitUntil(timeout: 5) { sut.summary(for: "retry").availability == .unavailable }
        #expect(sut.summary(for: "retry").files.count == 150)
        #expect(sut.summary(for: "retry").activity.edits == 150)
        let file = try FileHandle(forWritingTo: hidden)
        try file.seekToEnd()
        try file.write(contentsOf: Data(edit(151, path: "appended.swift").utf8))
        try file.close()
        try FileManager.default.moveItem(at: hidden, to: path)
        await waitUntil(timeout: 5) { sut.summary(for: "retry").availability == .available }
        #expect(sut.summary(for: "retry").activity.edits == 151)
        #expect(sut.summary(for: "retry").totalFiles == 151)
        #expect(sut.summary(for: "retry").files.count == 151)
    }

    @Test(.timeLimit(.minutes(1)))
    func givenUnavailableSummary_whenLastLeaseReleased_thenPendingRetryDoesNotPublishAfterFileCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sut = makeSUT(directory: directory)
        let lease = sut.acquireSummary("released")
        let states = LockedBox<[EventAvailability]>([])
        let observation = sut.summaryPublisher(for: "released").sink { value in states.mutate { $0.append(value.availability) } }
        await waitUntil { states.value.last == .unavailable }
        lease.release()
        try edit(1, path: "ignored.swift").write(to: directory.appendingPathComponent("released.events.jsonl"), atomically: true, encoding: .utf8)
        // Let one retry deadline pass while retaining the publisher, without retaining its stream.
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!states.value.contains(.available))
        #expect(sut.leasedTaskIDs.isEmpty)
        withExtendedLifetime(observation) {}
    }
}
