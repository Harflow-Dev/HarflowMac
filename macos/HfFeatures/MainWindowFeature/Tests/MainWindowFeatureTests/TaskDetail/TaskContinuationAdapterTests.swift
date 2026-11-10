import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskContinuationAdapterTests

@MainActor @Suite struct TaskContinuationAdapterTests {
    @Test func givenPairedCapabilities_whenPreparing_thenOneFreshHandshakeSupportsContinue() async {
        // given
        let runner = ContinuationSupportRunner(capabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors])
        let tooling = MockToolEnvironmentRepository()
        let client = CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: runner)
        given(tooling).ctl().willReturn(.success(client))
        let adapter = TaskDetailViewRepository(toolEnvironmentRepository: tooling)
        // when
        let supported = await adapter.continuationSupport(runtime: QualificationRuntimeToken(client: client))
        // then
        #expect(supported)
        #expect(await runner.calls == [["version-info", "--json"]])
    }

    @Test func givenOnlyOneCapabilityPerHandshake_whenPreparingAgain_thenSeparateProbesNeverCombine() async {
        // given
        let runner = ContinuationSupportRunner(capabilities: [CtlCapability.taskContinue])
        let tooling = MockToolEnvironmentRepository()
        let client = CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: runner)
        given(tooling).ctl().willReturn(.success(client))
        let adapter = TaskDetailViewRepository(toolEnvironmentRepository: tooling)
        let runtime = QualificationRuntimeToken(client: client)
        // when / then
        #expect(await adapter.continuationSupport(runtime: runtime) == false)
        await runner.setCapabilities([CtlCapability.taskSuccessors])
        #expect(await adapter.continuationSupport(runtime: runtime) == false)
        #expect(await runner.calls.count == 2)
    }

    @Test func givenRuntimeChangesDuringHandshake_whenOldProbeReturns_thenSupportIsRejected() async {
        // given
        let stream = AsyncStream<Void>.makeStream()
        let runner = ContinuationSupportRunner(capabilities: [CtlCapability.taskContinue, CtlCapability.taskSuccessors], gate: stream.stream)
        let tooling = MockToolEnvironmentRepository()
        let original = CtlClient(executable: "/fixture/original/harflow-ctl", environment: [:], runner: runner)
        let current = TaskDetailVMTests.Box(original)
        given(tooling).ctl().willProduce { .success(current.value) }
        let adapter = TaskDetailViewRepository(toolEnvironmentRepository: tooling)
        // when
        let work = Task { await adapter.continuationSupport(runtime: QualificationRuntimeToken(client: original)) }
        await waitUntil { runner.callCount == 1 }
        current.value = CtlClient(executable: "/fixture/replaced/harflow-ctl", environment: [:], runner: runner)
        stream.continuation.yield(())
        stream.continuation.finish()
        // then
        #expect(await work.value == false)
    }
}

// MARK: - ContinuationSupportRunner

private actor ContinuationSupportRunner: ProcessRunning {
    private nonisolated let count = ContinuationInvocationCount()
    nonisolated var callCount: Int { count.value }
    private var capabilities: [String]
    private let gate: AsyncStream<Void>?
    private(set) var calls: [[String]] = []

    init(capabilities: [String], gate: AsyncStream<Void>? = nil) {
        self.capabilities = capabilities
        self.gate = gate
    }

    func setCapabilities(_ value: [String]) { capabilities = value }

    func run(executable _: String, arguments: [String], environment: [String: String], currentDirectory _: String?,
             timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        calls.append(arguments)
        count.increment()
        let captured = capabilities
        if let gate { for await _ in gate { break } }
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"),
            "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
            "contracts": .object([
                "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                "events": .object(["format": .string("harflow.event"), "v": .number(1)])]),
            "capabilities": .array((["ctl.v1", "setup.v1", "events.v1"] + captured).map(JSONValue.string)),
            "os": .string("darwin"), "architecture": .string("arm64")
        ]
        return .success(ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: ""))
    }
}

private final class ContinuationInvocationCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}
