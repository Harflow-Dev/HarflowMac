import Foundation
@testable import MonitorCore
import Testing

// MARK: - WorkflowActivityTests

struct WorkflowActivityTests {
    private func runner(live: Bool = false, eventVersion: JSONValue? = .number(1),
                        payload: String = #"{"workflow_run_id":"run","execution_id":"exec","events":[],"has_more":false}"#,
                        operation: (@Sendable () -> Void)? = nil) -> RecordingRunner {
        RecordingRunner { call in
            if call.arguments == ["version-info", "--json"] {
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                var contracts: [String: JSONValue] = ["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)])]
                if let eventVersion { contracts["events"] = .object(["format": .string("harflow.event"), "v": eventVersion]) }
                let info: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.version-info"),
                    "v": .number(1), "product_version": .string(HarflowVersion.current), "component": .string("engine"),
                    "state_root": .string(root), "os": .string("darwin"), "architecture": .string("arm64"),
                    "contracts": .object(contracts),
                    "capabilities": .array((["ctl.v1", "events.v1"] + (live ? [CtlCapability.workflowLiveActivity] : [])).map(JSONValue.string))]
                return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(info).rendered().utf8), stderr: "")
            }
            operation?()
            return ProcessOutput(exitCode: 0, stdout: ctlJSON("{\"result\":\(payload)}"), stderr: "")
        }
    }

    @Test func givenLegacyEngine_whenSettledOnly_thenFirstReadNeedsNoNewSettlementMetadata() async throws {
        // given
        let runner = runner()
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let page = try await client.workflowActivity(runID: "run", executionID: "exec", intent: .settledOnly).get()
        // then
        #expect(page.settled == nil)
        #expect(runner.calls.count == 1)
    }

    @Test(arguments: [["--view=activity"], ["--view", "activity"]])
    func givenLegacyEngine_whenGenericSettledActivityRequested_thenNoUniversalCapabilityGate(options: [String]) async throws {
        // given
        let runner = runner()
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        _ = try await client.workflow("inspect", options: options, positionals: ["run", "exec"]).get()
        // then
        #expect(runner.calls.count == 1)
    }

    @Test func givenValidEnvelopeButMalformedEvent_whenActivityDecoded_thenNoEmptySuccess() async {
        // given
        let event = "{\"product\":\"harflow\",\"format\":\"harflow.event\",\"product_version\":\"\(HarflowVersion.current)\",\"v\":1,\"seq\":1}"
        let runner = runner(payload: "{\"workflow_run_id\":\"run\",\"execution_id\":\"exec\",\"events\":[\(event)],\"has_more\":false}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when / then
        guard case .failure = await client.workflowActivity(runID: "run", executionID: "exec", intent: .settledOnly) else {
            Issue.record("Malformed event became empty successful activity"); return
        }
    }

    @Test func givenLegacyEngine_whenUnsettledRequested_thenNoActivityCommandLaunches() async {
        // given
        let runner = runner()
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflowActivity(runID: "run", executionID: "exec", intent: .allowUnsettled)
        // then
        guard case .failure(let error) = result else { Issue.record("Expected capability refusal"); return }
        #expect(error == .unsupportedCommand(tool: "harflow-ctl", command: "workflow-inspect",
                                              detail: "Missing capability \(CtlCapability.workflowLiveActivity)"))
        #expect(runner.calls.isEmpty)
    }

    @Test func givenCapableEngine_whenUnsettledRequested_thenFactsSurvive() async throws {
        // given
        let runner = runner(live: true, payload: #"{"workflow_run_id":"run","execution_id":"exec","events":[],"has_more":false,"#
            + #""settled":false,"activity_state":"not_started"}"#)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let page = try await client.workflowActivity(runID: "run", executionID: "exec", intent: .allowUnsettled).get()
        // then
        #expect(page.settled == false)
        #expect(page.activityState == "not_started")
        #expect(runner.calls.count == 1)
    }

    @Test(arguments: [JSONValue?.none, .number(2), .string("1")], [["--view=activity"], ["--view", "activity"]])
    func givenMissingOrUnsupportedEventContract_whenEitherActivitySpelling_thenRefusesBeforeLaunch(version: JSONValue?, options: [String]) async {
        // given
        let runner = runner(live: true, eventVersion: version)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("inspect", options: options, positionals: ["run", "exec"])
        // then
        guard case .failure = result else { Issue.record("Expected event contract refusal"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: [["--view=activity"], ["--view", "activity"]])
    func givenOversizedActivity_whenEitherSpelling_thenSameByteBudgetApplies(options: [String]) async {
        // given
        let runner = runner(live: true, payload: "{\"padding\":\"\(String(repeating: "x", count: 262144))\"}")
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("inspect", options: options, positionals: ["run", "exec"])
        // then
        guard case .failure(let error) = result else { Issue.record("Expected byte refusal"); return }
        #expect(error.message.contains("byte limit"))
    }

    @Test(arguments: [["--view=activity"], ["--view", "activity"]])
    func givenMalformedNestedEvent_whenEitherSpelling_thenPageCannotBecomeEmptySuccess(options: [String]) async {
        // given
        let runner = runner(live: true, payload: #"{"workflow_run_id":"run","execution_id":"exec","events":[{"v":2}],"has_more":false}"#)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.workflow("inspect", options: options, positionals: ["run", "exec"])
        // then
        guard case .failure = result else { Issue.record("Expected nested event refusal"); return }
    }

    @Test func givenRuntimeChangesDuringResponse_whenActivityReturns_thenResultIsDiscarded() async {
        // given
        let state = ActivityCurrentFlag()
        let runner = runner(live: true, operation: { state.invalidate() })
        var client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        client.operationIsCurrent = { state.isCurrent }
        // when
        let result = await client.workflowActivity(runID: "run", executionID: "exec", intent: .allowUnsettled)
        // then
        guard case .failure = result else { Issue.record("Expected stale response refusal"); return }
        #expect(runner.calls.count == 1)
    }

    @Test func givenSettledOnlyIntent_whenProducerReportsUnsettled_thenRefuses() async {
        // given
        let runner = runner(payload: #"{"workflow_run_id":"run","execution_id":"exec","events":[],"has_more":false,"settled":false}"#)
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when / then
        guard case .failure = await client.workflowActivity(runID: "run", executionID: "exec", intent: .settledOnly) else {
            Issue.record("Expected settlement contradiction refusal"); return
        }
    }
}

private final class ActivityCurrentFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true
    var isCurrent: Bool { lock.withLock { current } }
    func invalidate() { lock.withLock { current = false } }
}
