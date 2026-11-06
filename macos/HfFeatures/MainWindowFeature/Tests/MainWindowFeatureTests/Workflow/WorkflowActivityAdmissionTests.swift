import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowActivityAdmissionTests

@MainActor
@Suite struct WorkflowActivityAdmissionTests {
    private var missingLiveCapability: ToolError {
        .unsupportedCommand(tool: "harflow-ctl", command: "workflow-inspect",
                            detail: "Missing capability \(CtlCapability.workflowLiveActivity)")
    }

    private func makeVM(useCase: ActivityAdmissionUseCase, complete: Bool, awaitActivity: Bool = true) async throws -> WorkflowVM {
        let routing = MockWorkflowRouting()
        given(routing).chooseDirectory().willReturn(nil)
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let raw: [String: JSONValue] = if complete { try await vm.runPolling.load(id: "run", useCase: useCase) } else { useCase.raw }
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = "node"
        await vm.sidebarTask?.value
        if awaitActivity { await vm.nativeActivityTask?.value }
        return vm
    }

    @Test func givenLegacyTerminalExecutionWithCompletePublicAttempts_whenFirstActivityLoads_thenSettledIntentPreservesOldReply() async throws {
        // given — status alone is insufficient; the public lossless snapshot includes every fallback attempt.
        let useCase = ActivityAdmissionUseCase()
        // when
        let vm = try await makeVM(useCase: useCase, complete: true)
        // then — the old reply has no `settled` field, but the consumer already captured positive evidence.
        #expect(useCase.intents == [.settledOnly])
        #expect(useCase.runner.activityCommands == 1)
        #expect(useCase.readErrors.isEmpty)
        #expect(vm.nativeActivity?.loaded == true)
        #expect(vm.nativeActivity?.items.isEmpty == false)
        #expect(vm.nativeActivity?.settled == nil)
    }

    @Test func givenTerminalStatusWithoutCompleteSnapshot_whenLegacyNativeWouldReturnOldSuccess_thenNoActivityCommandOrFold() async throws {
        // given — the fake older native engine would return success without settlement metadata if launched.
        let useCase = ActivityAdmissionUseCase()
        // when
        let vm = try await makeVM(useCase: useCase, complete: false)
        // then
        #expect(useCase.intents == [.allowUnsettled])
        #expect(useCase.runner.activityCommands == 0)
        #expect(useCase.readErrors == [missingLiveCapability])
        #expect(vm.nativeActivity?.error?.isEmpty == false)
        #expect(vm.nativeActivity?.loaded == false)
        #expect(vm.nativeActivity?.items.isEmpty == true)
    }

    @Test(arguments: [JSONValue.null, .array([.object(["task_id": .string("fallback"), "status": .string("uncertain")])]),
                       .array([.object(["task_id": .string("fallback"), "status": .string("future_terminal")])]), .array([.string("malformed")])])
    func givenUnknownMissingOrMalformedAttemptsInCompleteSnapshot_whenActivityLoads_thenLegacyReadIsNotAdmitted(tasks: JSONValue) async throws {
        // given
        let useCase = ActivityAdmissionUseCase(tasks: tasks)
        // when
        let vm = try await makeVM(useCase: useCase, complete: true)
        // then
        #expect(useCase.intents == [.allowUnsettled])
        #expect(useCase.runner.activityCommands == 0)
        #expect(useCase.readErrors == [missingLiveCapability])
        #expect(vm.nativeActivity?.error?.isEmpty == false)
        #expect(vm.nativeActivity?.loaded == false)
    }

    @Test func givenActivityReadInFlight_whenIdenticalUpdateArrives_thenNoSecondReadStarts() async throws {
        // given
        let useCase = ActivityAdmissionUseCase()
        useCase.pauseActivity = true
        let vm = try await makeVM(useCase: useCase, complete: true, awaitActivity: false)
        await waitUntil { useCase.pending != nil }
        // when
        vm.updateNativeActivity()
        // then
        #expect(useCase.runner.activityCommands == 1)
        useCase.pending?.resume()
        useCase.pending = nil
        await vm.nativeActivityTask?.value
        #expect(vm.nativeActivity?.loaded == true)
    }

    @Test func givenLoadedActivity_whenRefreshFails_thenExistingContentSurvives() async throws {
        // given
        let useCase = ActivityAdmissionUseCase()
        let vm = try await makeVM(useCase: useCase, complete: true)
        let previous = vm.nativeActivity?.items
        useCase.failActivity = true
        // when
        vm.updateNativeActivity()
        await vm.nativeActivityTask?.value
        // then
        #expect(vm.nativeActivity?.items == previous)
        #expect(vm.nativeActivity?.error != nil)
    }

    @Test(arguments: ["generation", "state-root", "missing-proof-runtime"])
    func givenCompleteSettlementProof_whenRuntimeChangesOrWasMissing_thenReusedIdsCannotAdmitLegacyActivity(change: String) async throws {
        // given
        let useCase = ActivityAdmissionUseCase()
        useCase.runtimeUnavailable = change == "missing-proof-runtime"
        let routing = MockWorkflowRouting()
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let original = try await vm.runPolling.load(id: "run", useCase: useCase)
        // when — preserve the exact run/activation bytes while changing immutable runtime generation.
        useCase.runtimeUnavailable = false
        if change == "state-root" { useCase.runtimeEnvironment = ["HOME": "/fixture/second-home"] }
        if change == "generation" { useCase.runtimePath = "/fixture/runtime-b/ctl" }
        vm.selectedRun = WorkflowRunModel(raw: original)
        vm.selectedNodeID = "node"
        await vm.sidebarTask?.value
        await vm.nativeActivityTask?.value
        // then — runtime B's unannotated native success would be returned if the operation launched.
        #expect(useCase.intents == [.allowUnsettled])
        #expect(useCase.runner.activityCommands == 0)
        #expect(useCase.readErrors == [missingLiveCapability])
        #expect(vm.nativeActivity?.error?.isEmpty == false)
        #expect(vm.nativeActivity?.loaded == false)
        #expect(vm.nativeActivity?.items.isEmpty == true)
        #expect(vm.runPolling.cached(id: "run") == nil)
    }

    @Test func givenSuccessfulNativeRead_whenRuntimeChangesBeforeAdoption_thenNoFold() async throws {
        // given
        let useCase = ActivityAdmissionUseCase()
        useCase.changeRuntimeAfterRead = true
        // when
        let vm = try await makeVM(useCase: useCase, complete: true)
        // then
        #expect(useCase.runner.activityCommands == 1)
        #expect(vm.nativeActivity?.loaded == false)
        #expect(vm.nativeActivity?.items.isEmpty == true)
    }

    @Test func givenSuccessfulNativeRead_whenActivationChangesDuringRead_thenNoFold() async throws {
        // given
        let useCase = ActivityAdmissionUseCase()
        useCase.pauseActivity = true
        let routing = MockWorkflowRouting()
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        let raw = try await vm.runPolling.load(id: "run", useCase: useCase)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = "node"
        await waitUntil { useCase.pending != nil }
        // when — same run and execution, but an unsettled fallback appeared.
        var next = vm.runSidebar
        var activation = next.attempts[0].raw
        activation["tasks"] = .array([.object(["task_id": .string("new"), "status": .string("reserved")])])
        next.attempts = [.init(id: "exec", title: "Attempt", raw: activation)]
        vm.runSidebar = next
        useCase.pending?.resume()
        useCase.pending = nil
        await vm.nativeActivityTask?.value
        // then
        #expect(vm.nativeActivity?.loaded == false)
        #expect(vm.nativeActivity?.items.isEmpty == true)
    }
}

@MainActor
private final class ActivityAdmissionUseCase: WorkflowUseCase, @unchecked Sendable {
    let runner = LegacyActivityRunner()
    var intents: [WorkflowActivityReadIntent] = []
    var readErrors: [ToolError] = []
    var runtimePath = "/fixture/old/ctl"
    var runtimeEnvironment: [String: String] = [:]
    var runtimeUnavailable = false
    var changeRuntimeAfterRead = false
    var pauseActivity = false
    var failActivity = false
    var pending: CheckedContinuation<Void, Never>?
    let raw: [String: JSONValue]
    var backendIDs: [String] { [] }

    init(tasks: JSONValue = .array([.object(["task_id": .string("first"), "status": .string("failed")]),
                                   .object(["task_id": .string("fallback"), "status": .string("completed")])])) {
        self.raw = ["workflow_run_id": .string("run"), "status": .string("completed"),
               "definition": .object(["nodes": .array([.object(["id": .string("node"), "type": .string("agent")])])]),
               "activations": .array([.object(["id": .string("exec"), "node_id": .string("node"), "role": .string("node"),
                                              "status": .string("completed"), "execution_kind": .string("native_subagent"), "tasks": tasks])])]
    }

    func activityRuntime() throws -> QualificationRuntimeToken {
        if runtimeUnavailable { throw QualificationSessionError.runtimeChanged }
        return QualificationRuntimeToken(client: CtlClient(executable: runtimePath, environment: runtimeEnvironment, runner: runner))
    }

    func activity(runID: String, executionID: String, intent: WorkflowActivityReadIntent,
                  runtime: QualificationRuntimeToken) async throws -> WorkflowActivityPage {
        intents.append(intent)
        if failActivity { throw ToolError.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "Fixture refresh failed") }
        let result = await CtlClient(executable: runtime.executable, environment: runtime.environment, runner: runner, compatibilityContext: runtime.context)
            .workflowActivity(runID: runID, executionID: executionID, intent: intent)
        if case .failure(let error) = result { readErrors.append(error) }
        let page = try result.get()
        if pauseActivity { await withCheckedContinuation { pending = $0 } }
        if changeRuntimeAfterRead { runtimePath = "/fixture/new/ctl" }
        return page
    }

    func command(_: String, options _: [String], positionals _: [String], runtime _: QualificationRuntimeToken?) async throws -> [String: JSONValue] {
        let content = JSONValue.object(raw).rendered()
        return ["monitor_snapshot": .bool(true), "workflow_run_id": .string("run"), "content_sha256": .string("frozen"),
                "offset": .number(0), "total_characters": .number(Double(content.utf8.count)), "chunk": .string(content), "next_cursor": .null]
    }

    func validate(definition _: JSONValue) async throws -> [String: JSONValue] { ["valid": .bool(true)] }
    func save(name _: String, definition _: JSONValue, expectedRevision _: Int, expectedWorkflowID _: String?) async throws -> [String: JSONValue] { [:] }
    func refreshTasks() async {}
    func modelOptions(backend _: String) async -> [ModelOption] { [] }
}

private final class LegacyActivityRunner: ProcessRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var activityCommands: Int { lock.withLock { count } }

    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        let document: [String: JSONValue]
        if arguments == ["version-info", "--json"] {
            document = ["product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
                        "product_version": .string(HarflowVersion.current), "component": .string("engine"),
                        "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
                        "os": .string("darwin"), "architecture": .string("arm64"),
                        "contracts": .object(["ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                                               "events": .object(["format": .string("harflow.event"), "v": .number(1)])]),
                        "capabilities": .array([.string("ctl.v1"), .string("events.v1")])]
        } else {
            lock.withLock { count += 1 }
            let event: JSONValue = .object(["product": .string("harflow"), "format": .string("harflow.event"), "v": .number(1),
                                           "product_version": .string(HarflowVersion.current), "kind": .string("assistant_text"),
                                           "seq": .number(1), "observed_at": .string("2026-10-14T17:46:40+00:00"), "text": .string("Old native reply")])
            document = ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                        "product_version": .string(HarflowVersion.current), "result": .object([
                            "workflow_run_id": .string("run"), "execution_id": .string("exec"), "events": .array([event]), "has_more": .bool(false)])]
        }
        return .success(ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(document).rendered().utf8), stderr: ""))
    }
}
