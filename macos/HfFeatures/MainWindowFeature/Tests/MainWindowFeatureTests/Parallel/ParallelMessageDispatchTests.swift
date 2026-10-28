import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - ParallelMessageDispatchTests

@MainActor struct ParallelMessageDispatchTests {
    @Test(arguments: [false, true])
    func givenColumnMessage_whenSentThroughRepository_thenUsesPublicRouteAndRetainsEngineRefusal(now: Bool) async throws {
        // given
        let runner = ParallelMessageRunner(supportsMessaging: true)
        let fixture = fixture(runner)
        // when
        try await fixture.repository.sendMessage("node-task", text: "  exact\nmessage  ", now: now)
        // then
        let calls = await runner.operations
        #expect(calls == [["send", "--delivery=\(now ? "now" : "queue")", "--monitor", "--json", "--", "node-task", "  exact\nmessage  "]])
        verify(fixture.actions).setOutcome(.value("node-task"), .value("Queued — Pending approval prevents immediate delivery.")).called(1)
        verify(fixture.snapshots).refresh(.value("node-task")).called(1)
        verify(fixture.listing).refresh().called(1)
        verify(fixture.actions).endBusy(.value("node-task")).called(1)
    }

    @Test func givenQueuedMessage_whenCancelled_thenExactPublicTaskAndMessageIDsAreUsed() async throws {
        // given
        let runner = ParallelMessageRunner(supportsMessaging: true)
        let fixture = fixture(runner)
        // when
        try await fixture.repository.cancelMessage("current-task", messageID: "queued-id")
        // then
        let calls = await runner.operations
        #expect(calls == [["cancel-message", "--monitor", "--json", "--", "current-task", "queued-id"]])
        verify(fixture.actions).setOutcome(.value("current-task"), .value("Queued message cancelled.")).called(1)
        verify(fixture.snapshots).refresh(.value("current-task")).called(1)
    }

    @Test func givenOlderEngine_whenMessageRequested_thenExplicitUnsupportedErrorIsRetainedWithoutOperation() async throws {
        // given
        let runner = ParallelMessageRunner(supportsMessaging: false)
        let fixture = fixture(runner)
        // when
        do {
            try await fixture.repository.sendMessage("task", text: "keep", now: true)
            Issue.record("Expected the capability refusal")
        } catch {
            // then
            let refusal = try #require(error as? ToolError)
            #expect(refusal.message.contains("messaging.v1"))
            verify(fixture.actions).setOutcome(.value("task"), .value(refusal.message)).called(1)
        }
        let calls = await runner.operations
        #expect(calls.isEmpty)
        verify(fixture.actions).endBusy(.value("task")).called(1)
    }

    private func fixture(_ runner: ParallelMessageRunner) -> (
        repository: ParallelViewRepository, actions: MockTaskActionRepository,
        snapshots: MockTaskSnapshotRepository, listing: MockTaskListRepository
    ) {
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/isolated/harflow-ctl", environment: [:], runner: runner)))
        let actions = MockTaskActionRepository()
        given(actions).tryBeginBusy(.any).willReturn(true)
        given(actions).endBusy(.any).willReturn()
        given(actions).setOutcome(.any, .any).willReturn()
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).refresh(.any).willReturn()
        let listing = MockTaskListRepository()
        given(listing).refresh().willReturn()
        return (ParallelViewRepository(taskListRepository: listing, taskSnapshotRepository: snapshots,
            taskActionRepository: actions, toolEnvironmentRepository: environment), actions, snapshots, listing)
    }
}

private actor ParallelMessageRunner: ProcessRunning {
    let supportsMessaging: Bool
    var operations: [[String]] = []
    init(supportsMessaging: Bool) { self.supportsMessaging = supportsMessaging }

    func run(executable: String, arguments: [String], environment: [String: String],
             currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        let json: [String: Any]
        if arguments == ["version-info", "--json"] {
            json = ["product": "harflow", "format": "harflow.version-info", "v": 1, "product_version": HarflowVersion.current,
                "component": "engine", "state_root": RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot,
                "contracts": ["ctl": ["format": "harflow.ctl", "v": 1], "events": ["format": "harflow.event", "v": 1]],
                "capabilities": supportsMessaging ? ["ctl.v1", "events.v1", "messaging.v1"] : ["ctl.v1", "events.v1"],
                "os": "darwin", "architecture": "arm64"]
        } else {
            operations.append(arguments)
            let result: [String: Any] = arguments.first == "cancel-message"
                ? ["status": "cancelled", "reason": "Queued message cancelled."]
                : ["status": "queued", "refusal": ["code": "pending_approval", "message": "Pending approval prevents immediate delivery."]]
            json = ["product": "harflow", "format": "harflow.ctl", "v": 1, "product_version": HarflowVersion.current, "result": result]
        }
        do {
            return .success(ProcessOutput(exitCode: 0, stdout: try JSONSerialization.data(withJSONObject: json), stderr: ""))
        } catch {
            return .failure(.launchFailed(tool: executable, detail: error.localizedDescription))
        }
    }
}
