import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
import Testing

@Suite(.serialized)
struct ResourceSlotsRepositoryImplTests {
    private func slotRunner(inventory: String, phase: String, taskTitle: String? = nil,
                            control: ResourceSlotsRunnerControl = ResourceSlotsRunnerControl(),
                            beforeVersionInfo: (@Sendable () -> Void)? = nil,
                            beforeStatusBatch: (@Sendable () -> Void)? = nil) -> StubProcessRunner {
        StubProcessRunner { call in
            if call.arguments == ["version-info", "--json"] {
                beforeVersionInfo?()
                let root = RuntimeCompatibilityContext.derived(environment: call.environment).expectedStateRoot
                let versionInfo = [
                    "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,",
                    "\"product_version\":\"0.0.1\",\"component\":\"engine\",\"state_root\":\"\(root)\",",
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},",
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},",
                    "\"events\":{\"format\":\"harflow.event\",\"v\":1}},",
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\",\"phase-slots.v1\"],",
                    "\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                ].joined()
                return .success(stdout(versionInfo))
            }
            switch call.arguments.first {
            case "resources":
                if control.takeResourceFailure() {
                    let refusal = [
                        "{\"product\":\"harflow\",\"format\":\"harflow.ctl\",\"v\":1,",
                        "\"product_version\":\"0.0.1\",\"error\":{\"code\":\"resource_busy\",",
                        "\"message\":\"temporary read failure\"}}"
                    ].joined()
                    return .success(stdout(refusal))
                }
                return .success(stdout(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","resources":\#(inventory)}"#))
            case "slot":
                return .success(stdout(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","result":\#(phase)}"#))
            case "status-batch":
                beforeStatusBatch?()
                let tasks = taskTitle.map { title in
                    Self.inventoryTaskIDs(inventory)
.map { id in
                        #"{"task_id":"\#(id)","status":"running","backend":"claude","title":"\#(title)"}"#
                    }
.joined(separator: ",")
                } ?? ""
                return .success(stdout(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","tasks":[\#(tasks)],"errors":{}}"#))
            default:
                Issue.record("Unexpected resource slot ctl invocation: \(call.arguments)")
                return .success(stdout("{}"))
            }
        }
    }

    private static func inventoryTaskIDs(_ raw: String) -> [String] {
        guard let value = JSONValue.parse(Data(raw.utf8))?.arrayValue else { return [] }
        return value.compactMap { entry -> [String]? in
            guard let object = entry.objectValue,
                  let holders = object["holders"]?.arrayValue else { return nil }
            return holders.compactMap { $0.objectValue?["owner"]?.objectValue?["task_id"]?.stringValue }
        }
.flatMap(\.self)
    }

    private func emptyInventory() -> String { "[]" }
    private func emptyPhase(service: String = "missing") -> String {
        "{\"leases\":[],\"truncated\":false,\"configuration\":{\"epoch\":0,\"names\":{}},\"service\":{\"state\":\"\(service)\"}}"
    }

    private func singleHolderInventory(taskID: String, reservationID: String) -> String {
        JSONValue.array([.object([
            "name": .string("sim"), "capacity": .number(1),
            "holders": .array([.object([
                "reservation_id": .string(reservationID), "names": .array([.string("sim")]),
                "state": .string("held"),
                "owner": .object(["kind": .string("task"), "task_id": .string(taskID)]),
                "generation": .number(1), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                "granted_at": .string("2026-10-31T00:00:01+00:00"), "purpose": .string("whole_task")
            ])]), "queue": .array([])
        ])])
.rendered()
    }

    private func makeTooling(_ client: CtlClient) -> MockToolEnvironmentRepository {
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        return tooling
    }

    @Test func givenObservationLease_whenFirstReadCompletes_thenCompleteAggregatePublishesAndIdenticalPollStaysQuiet() async {
        // given
        let scheduler = CapturingScheduler()
        let runner = slotRunner(inventory: emptyInventory(), phase: emptyPhase(service: "unknown"))
        let tooling = makeTooling(CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runner))
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: scheduler)
        let snapshots = LockedBox<[ResourceSlotsSnapshot]>([])
        let subscription = sut.snapshotPublisher().sink { snapshot in snapshots.mutate { $0.append(snapshot) } }
        let lease = await sut.acquireObservation()

        // when
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        let publishedCount = snapshots.value.count
        await waitUntil { scheduler.oneShotCount(interval: 5) > 0 }
        #expect(scheduler.fireOneShot(interval: 5))
        #expect(await resourceSlotsWaitUntil { runner.calls.filter { $0.arguments.first == "resources" }.count >= 2 })
        // A later single-flight pass cannot launch until the preceding poll finished applying its result.
        #expect(await resourceSlotsWaitUntil { scheduler.oneShotCount(interval: 5) > 0 })
        #expect(scheduler.fireOneShot(interval: 5))
        #expect(await resourceSlotsWaitUntil { runner.calls.filter { $0.arguments.first == "resources" }.count >= 3 })

        // then
        #expect(sut.snapshot.data?.resources.isEmpty == true)
        #expect(sut.snapshot.isStale == false)
        #expect(sut.snapshot.data?.phaseStatus.service == .unknown("unknown"))
        #expect(snapshots.value.count == publishedCount)
        await sut.releaseObservation(lease)
        subscription.cancel()
    }

    @Test func givenSameRuntimeRefreshFailsAfterEmptySuccess_whenRefreshed_thenEmptyEvidenceIsRetainedAsStale() async {
        // given
        let control = ResourceSlotsRunnerControl()
        let runner = slotRunner(inventory: emptyInventory(), phase: emptyPhase(), control: control)
        let client = CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runner)
        let tooling = MockToolEnvironmentRepository()
        let selected = LockedBox<Result<CtlClient, ToolError>>(.success(client))
        given(tooling).ctl().willProduce { selected.value }
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: NullScheduling())
        let lease = await sut.acquireObservation()
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        let retained = sut.snapshot.data
        control.failNextResourceRead()

        // when
        await sut.refresh()
        #expect(await resourceSlotsWaitUntil { sut.snapshot.isStale })

        // then
        #expect(sut.snapshot.data == retained)
        #expect(sut.snapshot.data?.resources.isEmpty == true)
        await sut.releaseObservation(lease)
    }

    @Test func givenRuntimeChangesDuringOwnerMetadataRead_whenOldReadCompletes_thenOnlyNewRuntimeTitlePublishes() async {
        // given
        let gate = AsyncGate()
        let reachedBatch = LockedBox(false)
        let inventory = singleHolderInventory(taskID: "task-1", reservationID: "task-hold")
        let runnerA = slotRunner(inventory: inventory, phase: emptyPhase(), taskTitle: "Runtime A") {
            reachedBatch.mutate { $0 = true }
            gate.waitSync()
        }
        let runnerB = slotRunner(inventory: inventory, phase: emptyPhase(), taskTitle: "Runtime B")
        let clientA = CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runnerA)
        let clientB = CtlClient(executable: "/runtime/b/ctl", environment: [:], runner: runnerB)
        let tooling = MockToolEnvironmentRepository()
        let selected = LockedBox(.success(clientA) as Result<CtlClient, ToolError>)
        given(tooling).ctl().willProduce { selected.value }
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: NullScheduling())
        let observedTitles = LockedBox<[String]>([])
        let subscription = sut.snapshotPublisher().sink { snapshot in
            observedTitles.mutate { $0 += snapshot.data?.owners.values.compactMap(\.title) ?? [] }
        }
        let lease = await sut.acquireObservation()

        // when
        #expect(await resourceSlotsWaitUntil { reachedBatch.value })
        selected.mutate { $0 = .success(clientB) }
        await sut.runtimeChanged()
        gate.open()

        // then
        #expect(await resourceSlotsWaitUntil {
            sut.snapshot.phase == .ready && sut.snapshot.data?.owners.values.contains { $0.title == "Runtime B" } == true
        })
        #expect(!observedTitles.value.contains("Runtime A"))
        #expect(sut.snapshot.data?.owners.values.contains { $0.title == "Runtime B" } == true)
        await sut.releaseObservation(lease)
        subscription.cancel()
    }

    @Test func givenLastObservationLeaseReleasesDuringCompatibilityProbe_whenProbeReturns_thenNoAggregateCommandLaunches() async {
        // given
        let gate = AsyncGate()
        let reachedProbe = LockedBox(false)
        let runner = slotRunner(inventory: emptyInventory(), phase: emptyPhase(), beforeVersionInfo: {
            reachedProbe.mutate { $0 = true }
            gate.waitSync()
        })
        let runnerB = slotRunner(inventory: emptyInventory(), phase: emptyPhase())
        let clientA = CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runner)
        let clientB = CtlClient(executable: "/runtime/b/ctl", environment: [:], runner: runnerB)
        let selected = LockedBox<Result<CtlClient, ToolError>>(.success(clientA))
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { selected.value }
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: NullScheduling())
        let lease = await sut.acquireObservation()

        // when
        #expect(await resourceSlotsWaitUntil { reachedProbe.value })
        await sut.releaseObservation(lease)
        #expect(sut.snapshot.phase == .loading)
        #expect(sut.snapshot.data == nil)
        selected.mutate { $0 = .success(clientB) }
        let nextLease = await sut.acquireObservation()
        gate.open()

        // then — B cannot complete until the cancelled A flight has finished and drained the queued pass.
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        #expect(runner.calls.map(\.arguments) == [["version-info", "--json"]])
        #expect(runnerB.calls.filter { $0.arguments.first == "resources" }.count == 1)
        #expect(runnerB.calls.filter { $0.arguments.first == "slot" }.count == 1)
        await sut.releaseObservation(nextLease)
    }

    @Test func givenObservationReappearsBeforeCancelledProbeReturns_whenItCompletes_thenFreshLeaseStartsANewRead() async {
        // given
        let gate = AsyncGate()
        let reachedProbe = LockedBox(false)
        let control = ResourceSlotsRunnerControl(blockFirstProbe: true)
        let runner = slotRunner(inventory: emptyInventory(), phase: emptyPhase(), control: control, beforeVersionInfo: {
            if control.takeProbeBlock() {
                reachedProbe.mutate { $0 = true }
                gate.waitSync()
            }
        })
        let tooling = makeTooling(CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runner))
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: NullScheduling())
        let firstLease = await sut.acquireObservation()

        // when
        #expect(await resourceSlotsWaitUntil { reachedProbe.value })
        await sut.releaseObservation(firstLease)
        let reappearedLease = await sut.acquireObservation()
        gate.open()

        // then
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        #expect(runner.calls.filter { $0.arguments.first == "resources" }.count == 1)
        #expect(runner.calls.filter { $0.arguments.first == "slot" }.count == 1)
        await sut.releaseObservation(reappearedLease)
    }

    @Test func givenMoreThanOneHundredUnqualifiedTaskOwners_whenMetadataRefreshes_thenBatchesRotateWithoutPerOwnerFallback() async throws {
        // given
        let scheduler = CapturingScheduler()
        let holders: [JSONValue] = (0 ..< 105).map { index in
            .object([
                "reservation_id": .string("hold-\(index)"), "names": .array([.string("sim")]),
                "state": .string("held"),
                "owner": .object(["kind": .string("task"), "task_id": .string("task-\(String(format: "%03d", index))")]),
                "generation": .number(1), "enqueued_at": .string("2026-10-31T00:00:00+00:00"),
                "granted_at": .string("2026-10-31T00:00:01+00:00"), "purpose": .string("whole_task")
            ])
        }
        let inventory = JSONValue.array([.object([
            "name": .string("sim"), "capacity": .number(105), "holders": .array(holders), "queue": .array([])
        ])])
.rendered()
        let runner = slotRunner(inventory: inventory, phase: emptyPhase())
        let tooling = makeTooling(CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runner))
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: scheduler)
        let lease = await sut.acquireObservation()

        // when
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        let baseline = Date(timeIntervalSince1970: 1_758_000_000)
        scheduler.advance(to: baseline.addingTimeInterval(61))
        await sut.refresh()
        #expect(await resourceSlotsWaitUntil { runner.calls.filter { $0.arguments.first == "status-batch" }.count >= 2 })
        await sut.refresh()
        #expect(await resourceSlotsWaitUntil { runner.calls.filter { $0.arguments.first == "status-batch" }.count >= 3 })

        // then — each pass respects the public batch cap; the rotating union covers the full set.
        let batches = runner.calls.filter { $0.arguments.first == "status-batch" }.compactMap { call in
            call.arguments
.first(where: { $0.hasPrefix("--task-ids=") })?
.dropFirst("--task-ids=".count)
                .split(separator: ",")
.map(String.init)
        }
        try #require(batches.count == 3)
        #expect(batches.allSatisfy { $0.count <= 100 })
        #expect(batches[0].count == 100)
        #expect(batches[1].count == 100)
        #expect(batches[2].count == 5)
        #expect(Set(batches.flatMap(\.self)).count == 105)
        #expect(runner.calls.allSatisfy { $0.arguments.first != "status" })
        #expect(sut.snapshot.data?.owners.values.allSatisfy { $0.title == nil && $0.destination == nil } == true)
        await sut.releaseObservation(lease)
    }

    @Test func givenSelectedRuntime_whenRevalidatedReleasedAndReacquired_thenIdentityChangesOnlyForADifferentRuntimeToken() async {
        // given
        let runnerA = slotRunner(inventory: emptyInventory(), phase: emptyPhase())
        let runnerB = slotRunner(inventory: emptyInventory(), phase: emptyPhase())
        let clientA = CtlClient(executable: "/runtime/a/ctl", environment: [:], runner: runnerA)
        let clientB = CtlClient(executable: "/runtime/b/ctl", environment: [:], runner: runnerB)
        let selected = LockedBox<Result<CtlClient, ToolError>>(.success(clientA))
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce { selected.value }
        let sut = ResourceSlotsRepositoryImpl(tooling: tooling, scheduler: NullScheduling())
        let firstLease = await sut.acquireObservation()
        #expect(await resourceSlotsWaitUntil { sut.snapshot.phase == .ready })
        let originalIdentity = sut.snapshot.runtimeIdentity
        #expect(originalIdentity != nil)

        // when: setup/readiness notifications revalidate the same actual selected client.
        await sut.runtimeChanged()
        #expect(sut.snapshot.runtimeIdentity == originalIdentity)
        await sut.releaseObservation(firstLease)
        #expect(sut.snapshot.runtimeIdentity == originalIdentity)
        let secondLease = await sut.acquireObservation()
        #expect(sut.snapshot.runtimeIdentity == originalIdentity)

        // then: changing the token creates a distinct identity, including during the loading reset.
        selected.mutate { $0 = .success(clientB) }
        await sut.runtimeChanged()
        let replacementIdentity = sut.snapshot.runtimeIdentity
        #expect(replacementIdentity != nil && replacementIdentity != originalIdentity)
        #expect(await resourceSlotsWaitUntil {
            sut.snapshot.phase == .ready && sut.snapshot.runtimeIdentity == replacementIdentity
                && runnerB.calls.contains { $0.arguments.first == "slot" }
        })
        #expect(sut.snapshot.runtimeIdentity == replacementIdentity)
        await sut.releaseObservation(secondLease)
        #expect(sut.snapshot.runtimeIdentity == replacementIdentity)
    }

}

private final class ResourceSlotsRunnerControl: @unchecked Sendable {
    private let lock = NSLock()
    private var failResourceRead = false
    private var blockFirstProbe: Bool

    init(blockFirstProbe: Bool = false) { self.blockFirstProbe = blockFirstProbe }

    func failNextResourceRead() {
        lock.lock(); defer { lock.unlock() }
        failResourceRead = true
    }

    func takeResourceFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let shouldFail = failResourceRead
        failResourceRead = false
        return shouldFail
    }

    func takeProbeBlock() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let shouldBlock = blockFirstProbe
        blockFirstProbe = false
        return shouldBlock
    }
}

// waitUntil returns Void and does not record a timeout; retain #expect failure reporting at each call site.
@MainActor
private func resourceSlotsWaitUntil(timeout: TimeInterval = 3, condition: @MainActor () -> Bool) async -> Bool {
    await waitUntil(timeout: timeout, condition: condition)
    return condition()
}
