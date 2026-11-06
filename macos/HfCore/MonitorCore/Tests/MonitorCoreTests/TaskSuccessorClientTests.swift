import Foundation
@testable import MonitorCore
import Testing

struct TaskSuccessorClientTests {
    @Test func givenMissingCapability_whenRequested_thenOnlyFreshHandshakeRuns() async {
        // given
        let runner = RecordingRunner { call in successorProbe(call.environment, capability: false) }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.taskSuccessorPage(predecessorTaskID: "root")
        // then
        guard case .failure(.unsupportedCommand) = result else { Issue.record("Missing capability accepted"); return }
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info"])
    }

    @Test func givenTwoPages_whenRequested_thenEachPageProbesAndUsesExactSelector() async throws {
        // given
        let runner = RecordingRunner { call in
            if call.arguments.first == "version-info" { return successorProbe(call.environment, capability: true) }
            let response = #"{"result":{"successor_scope":"recorded_tasks","predecessor_task_id":"root","items":[],"#
                + #""has_more":false,"bootstrap_pending":false,"next_cursor":null}}"#
            return ProcessOutput(exitCode: 0, stdout: ctlJSON(response), stderr: "")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        _ = try await client.taskSuccessorPage(predecessorTaskID: "root").get()
        _ = try await client.taskSuccessorPage(predecessorTaskID: "root", cursor: "opaque").get()
        // then
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "task-list-page", "version-info", "task-list-page"])
        #expect(runner.calls.last?.arguments == ["task-list-page", "--predecessor-task-id=root", "--limit=100", "--cursor=opaque", "--json"])
    }
}

private func successorProbe(_ environment: [String: String], capability: Bool) -> ProcessOutput {
    let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
        "product_version": .string(HarflowVersion.current), "component": .string("engine"),
        "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
        "contracts": .object(["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)])]),
        "capabilities": .array((["ctl.v1"] + (capability ? ["task-successors.v1"] : [])).map(JSONValue.string)),
        "os": .string("darwin"), "architecture": .string("arm64")]
    return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
}

extension TaskSuccessorClientTests {
    @Test func givenOversizedDocument_whenOperationResponds_thenTypedPageIsRefused() async {
        // given
        let runner = RecordingRunner { call in
            if call.arguments.first == "version-info" { return successorProbe(call.environment, capability: true) }
            let result = "{\"result\":{\"padding\":\"" + String(repeating: "x", count: 262144) + "\"}}"
            return ProcessOutput(exitCode: 0, stdout: ctlJSON(result), stderr: "")
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when / then
        guard case .failure(.unreadable) = await client.taskSuccessorPage(predecessorTaskID: "root") else {
            Issue.record("Oversized document accepted"); return
        }
    }
}
