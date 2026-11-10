import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - PendingFlowCtl

/// Fake public process boundary: the real pending-launch owner and the VM run unchanged on top of it.
private actor PendingFlowCtl: ProcessRunning {
    let id: String
    var disposition: String
    var latch: HostedContinuationLatch?
    private(set) var statusCalls = 0

    init(id: String, disposition: String) {
        self.id = id
        self.disposition = disposition
    }

    func setLatch(_ value: HostedContinuationLatch?) { latch = value }

    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        switch arguments.first {
        case "version-info": return .success(probe(environment))
        case "task-pending-page": return .success(envelope(page()))
        case "task-pending-status":
            statusCalls += 1
            await latch?.park()
            return .success(envelope(lookup()))
        default: return .failure(.unsupportedCommand(tool: "fixture ctl", command: arguments.first ?? "", detail: "Unexpected flow command"))
        }
    }

    private func page() -> [String: JSONValue] {
        ["scope": .string(TaskPendingLaunchWire.scope), "observed_at": .string("fixture"),
         "namespace_revision": .string(String(repeating: "b", count: 64)), "namespace_complete": .bool(true),
         "coverage": .string("complete"), "invalid_name_count": .number(0), "examined_count": .number(1),
         "has_more": .bool(false), "next_cursor": .null, "bound": .null,
         "items": .array([.object(PendingLaunchesFixture.item(id: id).raw)])]
    }

    private func lookup() -> [String: JSONValue] {
        disposition == "recorded"
            ? PendingLaunchesFixture.plainLookup(id: id, disposition: "recorded").raw
            : PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: id)).raw
    }

    private func envelope(_ result: [String: JSONValue]) -> ProcessOutput {
        let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1),
                                        "product_version": .string(HarflowVersion.current), "result": .object(result)]
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }

    private func probe(_ environment: [String: String]) -> ProcessOutput {
        let raw: [String: JSONValue] = [
            "product": .string("harflow"), "format": .string("harflow.version-info"), "v": .number(1),
            "product_version": .string(HarflowVersion.current), "component": .string("engine"),
            "state_root": .string(RuntimeCompatibilityContext.derived(environment: environment).expectedStateRoot),
            "contracts": .object([
                "ctl": .object(["format": .string("harflow.ctl"), "v": .number(1)]),
                "setup": .object(["format": .string("harflow.setup"), "v": .number(1)]),
                "events": .object(["format": .string("harflow.event"), "v": .number(1)])]),
            "capabilities": .array(["ctl.v1", "setup.v1", "events.v1", "task-pending-launch.v1"].map(JSONValue.string)),
            "os": .string("darwin"), "architecture": .string("arm64")]
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }
}

// MARK: - OwnerUseCase

/// The production forwarding, with an injected owner instead of the global environment.
@MainActor
private struct OwnerUseCase: PendingLaunchesUseCase {
    let owner: PendingLaunchRepositoryImpl
    var snapshot: PendingLaunchSnapshot { owner.snapshot }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { owner.snapshotPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? { owner.acquireReadLease() }
    func releaseReadLease(_ lease: PendingLaunchReadLease) { owner.releaseReadLease(lease) }
    func refresh(lease: PendingLaunchReadLease) async { await owner.refresh(lease: lease) }
    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection? {
        owner.bindSelection(taskID: taskID, lease: lease)
    }

    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup { await owner.check(selection: selection) }
    func resolveRecorded(selection: PendingLaunchSelection) async -> PendingLaunchRecordedResult {
        await owner.resolveRecorded(selection: selection)
    }
}

private final class RoutedIDs: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func add(_ value: String) { lock.withLock { stored.append(value) } }
}

// MARK: - PendingLaunchesOwnerFlowTests

@MainActor @Suite
struct PendingLaunchesOwnerFlowTests {
    private let id = "20261110-093000-a17c92"

    private struct Flow {
        let ctl: PendingFlowCtl
        let owner: PendingLaunchRepositoryImpl
        let sut: PendingLaunchesVM
        let routed: RoutedIDs
        let routing: MockPendingLaunchesRouting
    }

    private func flow(disposition: String) async -> Flow {
        let ctl = PendingFlowCtl(id: id, disposition: disposition)
        let tools = MockToolEnvironmentRepository()
        given(tools).tasksDirectory.willReturn("/fixture/state/tasks")
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: ctl)))
        let taskID = id
        let list = MockTaskListRepository()
        given(list).tasks.willReturn([])
        given(list).tasksPublisher().willReturn(Just([TaskInfo]()).eraseToAnyPublisher())
        given(list).refresh().willReturn()
        given(list).admitRecorded(.any, runtime: .any, gate: .any).willProduce { _, _, _ in
            TaskInfo(.object(["task_id": .string(taskID), "status": .string("running")]))!
        }
        let actions = TaskActionRepositoryImpl(toolEnvironment: tools, taskListRepository: list, snapshotRepository: NullTaskSnapshotRepository())
        let owner = PendingLaunchRepositoryImpl(tooling: tools, taskList: list, actions: actions,
                                                recovery: NullStateRecoveryRepository(), now: { .now })
        let routed = RoutedIDs()
        let routing = MockPendingLaunchesRouting()
        given(routing).openRecordedTask(.any).willProduce { routed.add($0) }
        let sut = PendingLaunchesVM(useCase: OwnerUseCase(owner: owner), routing: routing)
        sut.didAppear()
        await waitUntil { sut.presentation.kind == .inventory }
        return Flow(ctl: ctl, owner: owner, sut: sut, routed: routed, routing: routing)
    }

    @Test func givenRecordedLaunch_whenSelectedAndStatusChecked_thenRoutesTheAdmittedID() async {
        // given
        let flow = await flow(disposition: "recorded")
        defer { flow.sut.didDisappear() }
        // when
        flow.sut.didSelectRow(id)
        await waitUntil { flow.sut.detail?.kind == .recorded && flow.sut.detail?.isActionEnabled == true }
        #expect(flow.sut.detail?.kind == .recorded)
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { !flow.routed.values.isEmpty }
        // then
        #expect(flow.routed.values == [id])
    }

    @Test func givenCheckHeldOpen_whenBack_thenTheLateResultIsNeitherShownNorStored() async {
        // given
        let flow = await flow(disposition: "pending")
        defer { flow.sut.didDisappear() }
        let latch = HostedContinuationLatch()
        await flow.ctl.setLatch(latch)
        flow.sut.didSelectRow(id)
        await waitUntil { latch.arrived.value }
        // when
        flow.sut.didTapBack()
        await latch.release()
        await waitUntil { flow.sut.detail == nil && flow.sut.presentation.kind == .inventory }
        for _ in 0 ..< 30 { await Task.yield() }
        // then
        #expect(flow.sut.detail == nil)
        #expect(flow.owner.snapshot.lookups.isEmpty)
    }

    @Test func givenRuntimeChangeDuringStatusCheck_whenReleased_thenNoRouteHappens() async {
        // given
        let flow = await flow(disposition: "recorded")
        defer { flow.sut.didDisappear() }
        flow.sut.didSelectRow(id)
        await waitUntil { flow.sut.detail?.kind == .recorded && flow.sut.detail?.isActionEnabled == true }
        let latch = HostedContinuationLatch()
        await flow.ctl.setLatch(latch)
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { latch.arrived.value }
        // when
        flow.owner.runtimeChanged()
        await waitUntil { flow.sut.detail == nil }
        await latch.release()
        for _ in 0 ..< 30 { await Task.yield() }
        // then
        #expect(flow.routed.values.isEmpty)
        #expect(flow.sut.detail == nil)
    }

    @Test func givenCheckHeldOpen_whenBackAndSameRowReselected_thenSecondCheckWaitsInsteadOfBeingRefusedBusy() async {
        // given
        let flow = await flow(disposition: "pending")
        defer { flow.sut.didDisappear() }
        let latch = HostedContinuationLatch()
        await flow.ctl.setLatch(latch)
        flow.sut.didSelectRow(id)
        await waitUntil { latch.arrived.value }
        // when
        flow.sut.didTapBack()
        flow.sut.didSelectRow(id)
        for _ in 0 ..< 30 { await Task.yield() }
        // then: only the first call reached the engine so far.
        #expect(await flow.ctl.statusCalls == 1)
        await latch.release()
        await waitUntil { flow.sut.detail?.kind == .waiting }
        #expect(flow.sut.detail?.kind == .waiting)
        #expect(await flow.ctl.statusCalls == 2)
        #expect(flow.owner.snapshot.lookups.count == 1)
        #expect(flow.owner.snapshot.lookups.first?.failure == nil)
    }
}
