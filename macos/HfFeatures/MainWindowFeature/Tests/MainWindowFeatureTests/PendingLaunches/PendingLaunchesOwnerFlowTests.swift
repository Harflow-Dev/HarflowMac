import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - PendingFlowCtl

/// Fake public process boundary: the real pending-launch owner, the real task list and the VM run unchanged on top of it.
private actor PendingFlowCtl: ProcessRunning {
    var dispositions: [String: String]
    /// Parks every `task-pending-status` call until released.
    var pendingLatch: HostedContinuationLatch?
    /// Parks every ordinary `status` call (the recorded admission) until released.
    var statusLatch: HostedContinuationLatch?
    var statusFails = false
    private(set) var pendingCalls = 0

    init(dispositions: [String: String]) { self.dispositions = dispositions }

    func setPendingLatch(_ value: HostedContinuationLatch?) { pendingLatch = value }
    func setStatusLatch(_ value: HostedContinuationLatch?) { statusLatch = value }
    func setStatusFails(_ value: Bool) { statusFails = value }

    func run(executable _: String, arguments: [String], environment: [String: String],
             currentDirectory _: String?, timeout _: Double) async -> Result<ProcessOutput, ToolError> {
        switch arguments.first {
        case "version-info": return .success(probe(environment))
        case "task-pending-page": return .success(envelope(page()))
        case "task-pending-status":
            pendingCalls += 1
            let id = target(arguments)
            await pendingLatch?.park()
            return .success(envelope(lookup(id)))
        case "status":
            await statusLatch?.park()
            if statusFails { return .success(refusal()) }
            return .success(task(target(arguments)))
        default: return .failure(.unsupportedCommand(tool: "fixture ctl", command: arguments.first ?? "", detail: "Unexpected flow command"))
        }
    }

    private func target(_ arguments: [String]) -> String {
        arguments.compactMap { $0.hasPrefix("--task-id=") ? String($0.dropFirst("--task-id=".count)) : $0 }
            .first { dispositions[$0] != nil } ?? ""
    }

    private func page() -> [String: JSONValue] {
        ["scope": .string(TaskPendingLaunchWire.scope), "observed_at": .string("fixture"),
         "namespace_revision": .string(String(repeating: "b", count: 64)), "namespace_complete": .bool(true),
         "coverage": .string("complete"), "invalid_name_count": .number(0), "examined_count": .number(Double(dispositions.count)),
         "has_more": .bool(false), "next_cursor": .null, "bound": .null,
         "items": .array(dispositions.keys.sorted().map { .object(PendingLaunchesFixture.item(id: $0).raw) })]
    }

    private func lookup(_ id: String) -> [String: JSONValue] {
        dispositions[id] == "recorded"
            ? PendingLaunchesFixture.plainLookup(id: id, disposition: "recorded").raw
            : PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: id)).raw
    }

    private func base() -> [String: JSONValue] {
        ["product": .string("harflow"), "format": .string("harflow.ctl"), "v": .number(1), "product_version": .string(HarflowVersion.current)]
    }

    private func envelope(_ result: [String: JSONValue]) -> ProcessOutput {
        var raw = base()
        raw["result"] = .object(result)
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }

    private func task(_ id: String) -> ProcessOutput {
        var raw = base()
        raw["task"] = .object(["task_id": .string(id), "status": .string("running")])
        return ProcessOutput(exitCode: 0, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
    }

    private func refusal() -> ProcessOutput {
        var raw = base()
        raw["error"] = .object(["code": .string("refused"), "message": .string("status unavailable")])
        return ProcessOutput(exitCode: 1, stdout: Data(JSONValue.object(raw).rendered().utf8), stderr: "")
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
    private let idA = "20261110-093000-a17c92"
    private let idB = "20261110-093200-b28d03"

    private struct Flow {
        let ctl: PendingFlowCtl
        let owner: PendingLaunchRepositoryImpl
        let sut: PendingLaunchesVM
        let routed: RoutedIDs
        /// The VM holds routing weakly.
        let routing: MockPendingLaunchesRouting
    }

    /// The real owner and the real task list (recorded admission) over one fake public ctl boundary.
    private func flow(_ dispositions: [String: String]) async -> Flow {
        let ctl = PendingFlowCtl(dispositions: dispositions)
        let tools = MockToolEnvironmentRepository()
        given(tools).tasksDirectory.willReturn("/fixture/state/tasks")
        given(tools).ctl().willReturn(.success(CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: ctl)))
        given(tools).discoverEnvironment().willReturn(DiscoveryResult(loginPath: nil, uv: nil))
        let list = TaskListRepositoryImpl(
            toolEnvironment: tools, snapshotRepository: NullTaskSnapshotRepository(), eventStreamRepository: NullEventStreamRepository(),
            finishNotifier: NullFinishNotifier(), scheduler: NullScheduling(), visibility: NullMonitorVisibility(),
            compatibilityCheck: { _ in .success(()) }
        )
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

    private func selectRecorded(_ flow: Flow) async {
        flow.sut.didSelectRow(idA)
        await waitUntil { flow.sut.detail?.kind == .recorded && flow.sut.detail?.isActionEnabled == true }
    }

    @Test func givenRecordedLaunch_whenSelectedAndStatusChecked_thenRoutesTheAdmittedID() async {
        // given
        let flow = await flow([idA: "recorded"])
        defer { flow.sut.didDisappear() }
        // when
        await selectRecorded(flow)
        #expect(flow.sut.detail?.kind == .recorded)
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { !flow.routed.values.isEmpty }
        // then
        #expect(flow.routed.values == [idA])
    }

    @Test func givenAdmissionFailure_whenStatusChecked_thenTaskStatusUnavailableAndNoRoute() async {
        // given
        let flow = await flow([idA: "recorded"])
        defer { flow.sut.didDisappear() }
        await selectRecorded(flow)
        await flow.ctl.setStatusFails(true)
        // when
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { flow.sut.detail?.kind == .handoffFailed }
        // then
        #expect(flow.sut.detail?.title == "Task status unavailable")
        #expect(flow.routed.values.isEmpty)
    }

    @Test func givenAdmissionHeldOpen_whenBack_thenNothingRoutesOrShows() async {
        // given
        let flow = await flow([idA: "recorded"])
        defer { flow.sut.didDisappear() }
        await selectRecorded(flow)
        let latch = HostedContinuationLatch()
        await flow.ctl.setStatusLatch(latch)
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { latch.arrived.value }
        let pending = flow.sut.lastOperation
        // when
        flow.sut.didTapBack()
        await latch.release()
        await pending?.value
        // then
        #expect(flow.routed.values.isEmpty)
        #expect(flow.sut.detail == nil)
    }

    @Test func givenCheckHeldOpen_whenBack_thenTheLateResultIsNeitherShownNorStored() async {
        // given
        let flow = await flow([idA: "pending"])
        defer { flow.sut.didDisappear() }
        let latch = HostedContinuationLatch()
        await flow.ctl.setPendingLatch(latch)
        flow.sut.didSelectRow(idA)
        await waitUntil { latch.arrived.value }
        let pending = flow.sut.lastOperation
        // when
        flow.sut.didTapBack()
        await latch.release()
        await pending?.value
        // then
        #expect(flow.sut.detail == nil)
        #expect(flow.owner.snapshot.lookups.isEmpty)
    }

    @Test func givenRuntimeChangeDuringStatusCheck_whenReleased_thenNoRouteHappens() async {
        // given
        let flow = await flow([idA: "recorded"])
        defer { flow.sut.didDisappear() }
        await selectRecorded(flow)
        let latch = HostedContinuationLatch()
        await flow.ctl.setPendingLatch(latch)
        flow.sut.didTapCheckTaskStatus()
        await waitUntil { latch.arrived.value }
        let pending = flow.sut.lastOperation
        // when
        flow.owner.runtimeChanged()
        await waitUntil { flow.sut.detail == nil }
        await latch.release()
        await pending?.value
        // then
        #expect(flow.routed.values.isEmpty)
        #expect(flow.sut.detail == nil)
    }

    @Test func givenCheckHeldOpen_whenBackAndSameRowReselected_thenSecondCheckWaitsInsteadOfBeingRefusedBusy() async {
        // given
        let flow = await flow([idA: "pending"])
        defer { flow.sut.didDisappear() }
        let latch = HostedContinuationLatch()
        await flow.ctl.setPendingLatch(latch)
        flow.sut.didSelectRow(idA)
        await waitUntil { latch.arrived.value }
        // when
        flow.sut.didTapBack()
        flow.sut.didSelectRow(idA)
        // then: the second check is queued behind the parked first call.
        #expect(flow.sut.activeOperations == 2)
        #expect(await flow.ctl.pendingCalls == 1)
        await latch.release()
        await waitUntil { flow.sut.detail?.kind == .waiting }
        #expect(flow.sut.detail?.kind == .waiting)
        #expect(await flow.ctl.pendingCalls == 2)
        #expect(flow.owner.snapshot.lookups.count == 1)
        #expect(flow.owner.snapshot.lookups.first?.failure == nil)
    }

    @Test func givenCheckForAHeldOpen_whenBackAndOtherLaunchSelected_thenALateResultNeverShowsUnderB() async {
        // given: A answers "pending", B answers "recorded".
        let flow = await flow([idA: "pending", idB: "recorded"])
        defer { flow.sut.didDisappear() }
        let latch = HostedContinuationLatch()
        await flow.ctl.setPendingLatch(latch)
        flow.sut.didSelectRow(idA)
        await waitUntil { latch.arrived.value }
        // when
        flow.sut.didTapBack()
        flow.sut.didSelectRow(idB)
        await latch.release()
        await waitUntil { flow.sut.detail?.kind == .recorded }
        await flow.sut.lastOperation?.value
        // then
        #expect(flow.sut.detail?.kind == .recorded)
        #expect(flow.sut.detail?.facts.first?.value == idB)
        #expect(flow.owner.snapshot.lookups.map(\.selection.taskID) == [idB])
    }
}
