import Foundation
@testable import MonitorCore
import Testing

// MARK: - TaskPromptClientTests

struct TaskPromptClientTests {
    @Test func givenRepeatedReads_whenCapabilityDisappears_thenFreshProbePreventsSecondCommand() async throws {
        // given
        let probes = PromptCounter()
        let runner = RecordingRunner { call in
            if call.arguments.first == "version-info" {
                return promptProbe(call.environment, capability: probes.next() == 1)
            }
            return promptOutput(promptRaw(text: "hello"))
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let first = await client.taskPrompt(taskID: "task")
        let second = await client.taskPrompt(taskID: "task")
        // then
        #expect(try first.get().text == "hello")
        guard case .failure(.unsupportedCommand) = second else { Issue.record("Missing capability must refuse"); return }
        #expect(runner.allCalls.map(\.arguments.first) == ["version-info", "task-prompt", "version-info"])
    }

    @Test(arguments: [1, 65536, 131072])
    func givenValidBoundAndOptionLikeID_whenRead_thenArgumentsAreProtected(limit: Int) async throws {
        // given
        let runner = RecordingRunner { call in
            call.arguments.first == "version-info" ? promptProbe(call.environment) : promptOutput(promptRaw(taskID: "--help", text: "x"))
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.taskPrompt(taskID: "--help", maxBytes: limit)
        // then
        #expect(try result.get().taskID == "--help")
        #expect(runner.calls.map(\.arguments) == [["task-prompt", "--max-bytes=\(limit)", "--json", "--", "--help"]])
    }

    @Test(arguments: [0, 131073])
    func givenInvalidBound_whenRead_thenNoProcessLaunches(limit: Int) async {
        // given
        let runner = RecordingRunner { _ in Issue.record("Invalid bounds must not launch"); return promptOutput(promptRaw(text: "x")) }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.taskPrompt(taskID: "task", maxBytes: limit)
        // then
        guard case .failure = result else { Issue.record("Invalid bound accepted"); return }
        #expect(runner.allCalls.isEmpty)
    }

    @Test(arguments: ["foreign-root", "wrong-contract", "failed-probe"])
    func givenIncompatibleRuntime_whenRead_thenNoPromptCommandLaunches(mode: String) async {
        // given
        let runner = RecordingRunner { call in
            if mode == "failed-probe" { return ProcessOutput(exitCode: 1, stdout: Data(), stderr: "probe failed") }
            return promptProbe(call.environment, root: mode == "foreign-root" ? "/foreign" : nil, contract: mode == "wrong-contract" ? 99 : 1)
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let result = await client.taskPrompt(taskID: "task")
        // then
        guard case .failure = result else { Issue.record("Incompatible runtime accepted"); return }
        #expect(runner.calls.isEmpty)
    }

    @Test(arguments: ["agent_caller", "caller_undecidable", "task_pending_launch", "unknown_task", "retention_active"])
    func givenStructuredRefusal_whenRead_thenCodeAndDetailsSurvive(code: String) async {
        // given
        let runner = RecordingRunner { call in
            if call.arguments.first == "version-info" { return promptProbe(call.environment) }
            let refusal = """
            {"v":1,"error":{"code":"\(code)","message":"refused","data":{"task_id":"task"}}}
            """
            return ProcessOutput(exitCode: 1, stdout: ctlJSON(refusal), stderr: "")
        }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskPrompt(taskID: "task")
        // then
        guard case .failure(let error) = result else { Issue.record("Refusal accepted as prompt"); return }
        #expect(error.refusalCode == code)
        #expect(error.refusalData == ["task_id": .string("task")])
    }

    @Test(arguments: ["exact", "prefix", "wrong-input", "wrong-resolution", "no-resolution", "short-prefix"])
    func givenResponseIdentity_whenRead_thenOnlyExactOrProvenPrefixIsAccepted(mode: String) async {
        // given
        let full = "abcdefgh-full-task"
        let requested = mode == "exact" ? "tiny" : mode == "short-prefix" ? "abc" : "abcdefgh"
        var raw = promptRaw(taskID: mode == "exact" ? "tiny" : full, text: "x")
        if mode != "exact", mode != "no-resolution" {
            raw["resolved_from"] = .object(["input": .string(mode == "wrong-input" ? "other" : requested),
                                            "task_id": .string(mode == "wrong-resolution" ? "other" : full)])
        }
        let response = promptOutput(raw)
        let runner = RecordingRunner { call in call.arguments.first == "version-info" ? promptProbe(call.environment) : response }
        // when
        let result = await CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner).taskPrompt(taskID: requested)
        // then
        if mode == "exact" || mode == "prefix" {
            #expect((try? result.get()) != nil)
        } else {
            guard case .failure = result else { Issue.record("Foreign identity accepted"); return }
        }
    }

    @Test(arguments: ["before", "probe", "command"])
    func givenCancellation_whenReadSuspends_thenNoCancelledResponseEscapes(stage: String) async {
        // given
        let runner = RecordingRunner { call in
            let isProbe = call.arguments.first == "version-info"
            if (stage == "probe" && isProbe) || (stage == "command" && !isProbe) {
                withUnsafeCurrentTask { $0?.cancel() }
            }
            return isProbe ? promptProbe(call.environment) : promptOutput(promptRaw(text: "late"))
        }
        let client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        // when
        let operation = Task {
            if stage == "before" { withUnsafeCurrentTask { $0?.cancel() } }
            return await client.taskPrompt(taskID: "task")
        }
        let result = await operation.value
        // then
        guard case .failure = result else { Issue.record("Cancelled response escaped"); return }
        #expect(runner.calls.count == (stage == "command" ? 1 : 0))
        if stage == "before" { #expect(runner.allCalls.isEmpty) }
    }

    @Test func givenGenerationChangesDuringCommand_whenReadCompletes_thenLateSuccessIsRefused() async {
        // given
        let current = PromptCounter()
        let runner = RecordingRunner { call in
            if call.arguments.first == "version-info" { return promptProbe(call.environment) }
            _ = current.next()
            return promptOutput(promptRaw(text: "obsolete"))
        }
        var client = CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)
        client.operationIsCurrent = { current.value == 0 }
        // when
        let result = await client.taskPrompt(taskID: "task")
        // then
        guard case .failure = result else { Issue.record("Obsolete response escaped"); return }
    }
}

private final class PromptCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

private func promptOutput(_ raw: [String: JSONValue]) -> ProcessOutput {
    ProcessOutput(exitCode: 0, stdout: ctlJSON(JSONValue.object(["result": .object(raw)]).rendered()), stderr: "")
}

private func promptProbe(_ environment: [String: String], capability: Bool = true, root: String? = nil, contract: Int = 1) -> ProcessOutput {
    let selectedRoot = root ?? RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    let contracts: [String: JSONValue] = ["ctl": .object(["format": .string("harflow.ctl"), "v": .number(Double(contract))]),
                                         "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                                         "events": .object(["format": .string("harflow.event"), "v": .number(1)])]
    let capabilities = ["ctl.v1", "setup.v1", "events.v1"] + (capability ? ["task-prompt.v1"] : [])
    let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
        "product_version": .string(HarflowVersion.current), "component": .string("engine"), "state_root": .string(selectedRoot),
        "contracts": .object(contracts), "capabilities": .array(capabilities.map(JSONValue.string)),
        "os": .string("darwin"), "architecture": .string("arm64")]
    return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
}
