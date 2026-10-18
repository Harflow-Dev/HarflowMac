import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

@Suite struct UnstampedEventSummaryTests {
    @Test func givenUnstampedEventFile_whenSummaryLoads_thenAvailabilityIsUnavailable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("task.events.jsonl")
        try (#"{"v":1,"seq":1,"kind":"notice"}"# + "\n")
            .write(to: path, atomically: true, encoding: .utf8)

        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(directory.path)
        let repository = EventStreamRepositoryImpl(
            toolEnvironment: environment,
            snapshotRepository: NullTaskSnapshotRepository(),
            scheduler: NullScheduling(),
            compatibilityCheck: { _ in .success(()) }
        )
        let lease = repository.acquireSummary("task")
        defer { lease.release() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, repository.summary(for: "task").availability != .unavailable {
            try await Task.sleep(for: .milliseconds(50))
        }
        let history = repository.history(for: "task")
        #expect(history.error == "Unsupported Harflow event envelope")
    }
}
