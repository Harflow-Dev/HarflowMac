import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

// MARK: - TaskPromptRepositoryTests

struct TaskPromptRepositoryTests {
    @Test func givenNullRepository_whenRead_thenUnavailableIsExplicit() async {
        // given / when
        let result = await NullTaskPromptRepository().read(taskID: "task", maxBytes: 65536, operationIsCurrent: { true })
        // then
        guard case .failure = result else { Issue.record("Null must not fabricate a prompt"); return }
    }

    @Test(arguments: ["available", "preview_only", "integrity_failed", "unavailable"])
    func givenPromptState_whenRead_thenAllFactsArePreserved(state: String) async throws {
        // given
        let output = repositoryPromptOutput(state: state)
        let runner = repositoryPromptRunner { _ in output }
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let recovery = StateRecoveryRepositoryImpl(toolEnvironment: tools)
        let repository = TaskPromptRepositoryImpl(toolEnvironment: tools, recovery: recovery)
        // when
        let result = await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { true })
        // then
        let value = try result.get()
        #expect(value.state.rawValue == state)
        #expect(value.text == (["available", "preview_only"].contains(state) ? " \n🙂\t" : nil))
        #expect(recovery.state == .idle)
        #expect(runner.calls.filter { $0.arguments.first == "task-prompt" }.count == 1)
    }

    @Test func givenTwoReads_whenCapabilityChanges_thenSecondReadHasNoCachedPermissionOrFallback() async throws {
        // given
        let capable = LockedBox(true)
        let runner = repositoryPromptRunner(capability: { capable.value }) { _ in repositoryPromptOutput() }
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let repository = TaskPromptRepositoryImpl(toolEnvironment: tools, recovery: StateRecoveryRepositoryImpl(toolEnvironment: tools))
        // when
        let first = await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { true })
        capable.mutate { $0 = false }
        let second = await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { true })
        // then
        #expect(try first.get().state == .available)
        guard case .failure(.unsupportedCommand) = second else { Issue.record("Missing capability must remain an error"); return }
        #expect(runner.calls.filter { $0.arguments.first == "version-info" }.count == 2)
        #expect(runner.calls.filter { $0.arguments.first == "task-prompt" }.count == 1)
    }

    @Test(arguments: ["executable", "environment", "root", "caller-ABA", "captured-fence", "cancellation", "stale-error"])
    func givenSuspendedCommand_whenRequestBecomesObsolete_thenLateResponseAndRecoveryAreDiscarded(mode: String) async {
        // given
        let entered = PromptReadLatch()
        let release = PromptReadLatch()
        let runner = SuspendedPromptRunner(entered: entered, release: release, failure: mode == "stale-error")
        let generation = LockedBox(0)
        let capturedCurrent = LockedBox(true)
        var original = CtlClient(executable: "/fixture/ctl", environment: ["HOME": "/tmp/prompt-test"], runner: runner)
        original.operationIsCurrent = { capturedCurrent.value }
        let selected = LockedBox(original)
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willProduce { .success(selected.value) }
        let recovery = StateRecoveryRepositoryImpl(toolEnvironment: tools)
        let repository = TaskPromptRepositoryImpl(toolEnvironment: tools, recovery: recovery)
        let task = Task { await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { generation.value == 0 }) }
        // when
        await entered.wait()
        switch mode {
        case "executable": selected.mutate { $0.executable = "/replacement/ctl" }
        case "environment": selected.mutate { $0.environment["PROMPT_GENERATION"] = "new" }
        case "root": selected.mutate { $0 = CtlClient(executable: $0.executable, environment: ["HOME": "/tmp/another-prompt-root"], runner: runner) }
        case "captured-fence": capturedCurrent.mutate { $0 = false }
        case "cancellation": task.cancel()
        default: generation.mutate { $0 += 2 }
        }
        await release.open()
        let result = await task.value
        // then
        guard case .failure(let error) = result else { Issue.record("Obsolete result escaped"); return }
        #expect(error.refusalCode != "state_incompatible")
        #expect(recovery.state == .idle)
    }

    @Test func givenCurrentStructuredStoreRefusal_whenRead_thenRecoveryReceivesIt() async {
        // given
        let runner = repositoryPromptRunner { _ in
            stdout("""
                {"product":"harflow","format":"harflow.ctl",
                "product_version":"\(HarflowVersion.current)","v":1,
                "error":{"code":"state_incompatible","message":"store refused"}}
                """)
        }
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let recovery = StateRecoveryRepositoryImpl(toolEnvironment: tools)
        let repository = TaskPromptRepositoryImpl(toolEnvironment: tools, recovery: recovery)
        // when
        let result = await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { true })
        // then
        guard case .failure(let error) = result else { Issue.record("Store refusal accepted"); return }
        #expect(error.refusalCode == "state_incompatible")
        #expect(recovery.state == .incompatible(error))
    }

    @Test func givenObsoleteCallerBeforeRead_whenRequested_thenNoProcessLaunches() async {
        // given
        let runner = repositoryPromptRunner { _ in Issue.record("Obsolete request launched"); return repositoryPromptOutput() }
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let repository = TaskPromptRepositoryImpl(toolEnvironment: tools, recovery: StateRecoveryRepositoryImpl(toolEnvironment: tools))
        // when
        let result = await repository.read(taskID: "task", maxBytes: 65536, operationIsCurrent: { false })
        // then
        guard case .failure = result else { Issue.record("Obsolete request accepted"); return }
        #expect(runner.calls.isEmpty)
    }
}

private actor PromptReadLatch {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume() }
    }
}

private struct SuspendedPromptRunner: ProcessRunning {
    let entered: PromptReadLatch
    let release: PromptReadLatch
    let failure: Bool
    func run(
        executable _: String, arguments: [String], environment: [String: String],
        currentDirectory _: String?, timeout _: Double
    ) async -> Result<ProcessOutput, ToolError> {
        if arguments.first == "version-info" { return .success(repositoryPromptProbe(environment)) }
        await entered.open()
        await release.wait()
        if failure {
            return .success(stdout("""
                {"product":"harflow","format":"harflow.ctl",
                "product_version":"\(HarflowVersion.current)","v":1,
                "error":{"code":"state_incompatible","message":"obsolete refusal"}}
                """))
        }
        return .success(repositoryPromptOutput())
    }
}

private func repositoryPromptRunner(
    capability: @escaping @Sendable () -> Bool = { true },
    answer: @escaping @Sendable (StubProcessRunner.Call) -> ProcessOutput
) -> StubProcessRunner {
    StubProcessRunner { call in
        .success(call.arguments.first == "version-info" ? repositoryPromptProbe(call.environment, capability: capability()) : answer(call))
    }
}

private func repositoryPromptProbe(_ environment: [String: String], capability: Bool = true) -> ProcessOutput {
    let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    let capabilityJSON = capability ? ",\"task-prompt.v1\"" : ""
    return stdout("""
        {"product":"harflow","format":"harflow.version-info","v":1,
        "product_version":"\(HarflowVersion.current)","component":"engine","state_root":"\(root)",
        "contracts":{"ctl":{"format":"harflow.ctl","v":1},
        "setup":{"format":"harflow.setup","v":1},
        "events":{"format":"harflow.event","v":1}},
        "capabilities":["ctl.v1","setup.v1","events.v1"\(capabilityJSON)],
        "os":"darwin","architecture":"arm64"}
        """)
}

private func repositoryPromptOutput(state: String = "available") -> ProcessOutput {
    let hasText = ["available", "preview_only"].contains(state)
    let integrity = state == "integrity_failed" ? "failed" : state == "available" ? "verified" : "not_applicable"
    let text = " \n🙂\t"
    let prompt: [String: JSONValue] = ["state": .string(state), "text": hasText ? .string(text) : .null,
        "returned_bytes": .number(Double(hasText ? text.utf8.count : 0)),
        "total_bytes": state == "available" ? .number(Double(text.utf8.count)) : .null,
        "complete": .bool(state == "available"), "truncated": .bool(false), "integrity": .string(integrity)]
    let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"), "product_version": .string(HarflowVersion.current),
        "v": .number(1), "result": .object(["task_id": .string("task"), "title": .string("Review"), "prompt": .object(prompt)])]
    return stdout(JSONValue.object(raw).rendered())
}
