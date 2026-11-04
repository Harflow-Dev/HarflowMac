import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

// MARK: - BoundPublicEventObservationReaderTests

@Suite struct BoundPublicEventObservationReaderTests {
    @Test(arguments: [
        "probe-executable", "response-environment", "response-root", "response-ABA",
        "response-captured-fence", "response-cancellation", "response-late-error"
    ])
    func givenSuspendedPublicRead_whenSelectedBindingBecomesObsolete_thenNoLatePageOrRefusalEscapes(mode: String) async {
        // given
        let entered = EventReaderLatch()
        let release = EventReaderLatch()
        let runner = SuspendedEventRunner(entered: entered, release: release,
            pauseProbe: mode.hasPrefix("probe"), failure: mode == "response-late-error")
        let generation = LockedBox(0)
        let capturedFence = LockedBox(true)
        var original = CtlClient(executable: "/fixture/ctl", environment: ["HOME": "/tmp/event-reader-root"], runner: runner)
        original.operationIsCurrent = { capturedFence.value }
        let selected = LockedBox(original)
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willProduce { .success(selected.value) }
        let sut = BoundPublicEventObservationReader(tooling: tools)
        let task = Task { await sut.read(taskID: "task", position: .newest, operationIsCurrent: { generation.value == 0 }) }
        await entered.wait()
        // when
        switch mode {
        case "probe-executable": selected.mutate { $0.executable = "/replacement/ctl" }
        case "response-environment": selected.mutate { $0.environment["EVENT_GENERATION"] = "new" }
        case "response-root":
            selected.mutate { $0 = CtlClient(executable: $0.executable, environment: ["HOME": "/tmp/replacement-event-root"], runner: runner) }
        case "response-captured-fence": capturedFence.mutate { $0 = false }
        case "response-cancellation": task.cancel()
        default:
            // A -> B -> A returns the same binding; the explicit caller generation still fences it.
            selected.mutate { $0.executable = "/replacement/ctl" }
            generation.mutate { $0 += 1 }
            selected.mutate { $0.executable = "/fixture/ctl" }
            generation.mutate { $0 += 1 }
        }
        await release.open()
        let result = await task.value
        // then
        guard case .failure(let error) = result else { Issue.record("Obsolete public event page escaped"); return }
        #expect(error.refusalCode != "state_incompatible")
        if mode.hasPrefix("probe") { #expect(runner.commandCount.value == 0) }
    }

    @Test func givenCurrentBinding_whenTwoPagesRead_thenEveryOperationPerformsFreshCapabilityProbe() async throws {
        // given
        let probes = LockedBox(0)
        let runner = StubProcessRunner { call in
            if call.arguments.first == "version-info" {
                probes.mutate { $0 += 1 }
                return .success(eventReaderProbe(call.environment))
            }
            return .success(eventReaderPage())
        }
        let tools = MockToolEnvironmentRepository()
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/ctl", environment: [:], runner: runner)))
        let sut = BoundPublicEventObservationReader(tooling: tools)
        // when
        let first = await sut.read(taskID: "task", position: .newest, operationIsCurrent: { true })
        let second = await sut.read(taskID: "task", position: .cursor("live"), operationIsCurrent: { true })
        // then
        #expect(try first.get().newerCursor == "live")
        #expect(try second.get().newerCursor == "live")
        #expect(probes.value == 2)
    }
}

private actor EventReaderLatch {
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

private struct SuspendedEventRunner: ProcessRunning {
    let entered: EventReaderLatch
    let release: EventReaderLatch
    let pauseProbe: Bool
    let failure: Bool
    let commandCount = LockedBox(0)
    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        let probe = arguments.first == "version-info"
        if probe == pauseProbe {
            await entered.open()
            await release.wait()
        }
        if probe { return .success(eventReaderProbe(environment)) }
        commandCount.mutate { $0 += 1 }
        if failure {
            return .success(stdout("""
                {"product":"harflow","format":"harflow.ctl","v":1,"product_version":"\(HarflowVersion.current)",
                "error":{"code":"state_incompatible","message":"obsolete refusal"}}
                """))
        }
        return .success(eventReaderPage())
    }
}

private func eventReaderProbe(_ environment: [String: String]) -> ProcessOutput {
    let root = RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot
    return stdout("""
        {"product":"harflow","format":"harflow.version-info","v":1,
        "product_version":"\(HarflowVersion.current)","component":"engine","state_root":"\(root)",
        "contracts":{"ctl":{"format":"harflow.ctl","v":1},"events":{"format":"harflow.event","v":1}},
        "capabilities":["ctl.v1","events.v1","task-event-page.v1"],"os":"darwin","architecture":"arm64"}
        """)
}

private func eventReaderPage() -> ProcessOutput {
    let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"),
        "v": .number(1), "product_version": .string(HarflowVersion.current), "result": .object(ObservationFixtures.page().raw)]
    return stdout(JSONValue.object(raw).rendered())
}
