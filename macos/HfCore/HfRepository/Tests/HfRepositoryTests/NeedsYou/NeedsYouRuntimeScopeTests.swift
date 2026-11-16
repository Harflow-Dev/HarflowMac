import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - NeedsYouRuntimeScopeTests

@Suite struct NeedsYouRuntimeScopeTests {
    @Test func givenBudgetDeferredRuntimeA_whenRuntimeBIsSelected_thenAcquisitionRestartsWithoutCachedActionsOrCursors() async throws {
        // given — A retains partial approval pages/details because the full acquisition exceeds one pass.
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        engine.tasks = [awaitingTask("t1", awaiting: 70)]
        engine.approvalPageSize = 16
        let rows = (0 ..< 70).map { approval(id: "r\($0)", command: "runtime-A") }
        engine.approvalRows["t1"] = rows
        engine.approvalDetails = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let sut = repository(engine, owner: owner)
        await sut.runPass()
        #expect(sut.snapshot.items.isEmpty && sut.snapshot.deferredSourceCount > 0)
        // when — same request ID/revision and executable, a different selected environment/epoch.
        owner.select("B")
        let requestB = approval(id: "r0", command: "runtime-B")
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [requestB]
        engine.approvalDetails = [requestB.id: requestB]
        engine.resetCalls()
        await sut.runPass()
        // then
        let item = try #require(sut.snapshot.items.first)
        #expect(sut.snapshot.items.count == 1)
        #expect(item.approval == requestB)
        #expect(item.approvalContext == (try owner.context()))
        #expect(engine.calls.contains("approvalGet:r0"))
        #expect(sut.snapshot.withdrawn.isEmpty)
    }

    @Test func givenRuntimeAPassSuspends_whenBPublishesBeforeAReturns_thenAOutputCannotContaminateB() async throws {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let first = approval(command: "runtime-A")
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [first]
        let gate = NeedsYouScopeGate()
        let calls = LockedBox(0)
        let next = LockedBox(first)
        engine.approvalDetailRead = { _, _ in
            let captured = next.value
            var firstRead = false
            calls.mutate { $0 += 1; firstRead = $0 == 1 }
            if firstRead { await gate.wait() }
            return captured
        }
        let sut = repository(engine, owner: owner)
        let oldPass = Task { await sut.runPass() }
        await waitUntil { gate.isWaiting }
        // when
        owner.select("B")
        let second = approval(command: "runtime-B")
        next.mutate { $0 = second }
        engine.approvalRows["t1"] = [second]
        await sut.runPass()
        gate.release()
        await oldPass.value
        // then
        #expect(sut.snapshot.items.first?.approval == second)
        #expect(sut.snapshot.items.first?.approvalContext == (try owner.context()))
        await sut.runPass()
        #expect(sut.snapshot.items.first?.approval == second)
    }

    @Test func givenRuntimeAResponseSuspends_whenBPublishesSameID_thenOldSettlementCannotSuppressB() async throws {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let first = approval(command: "runtime-A")
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [first]
        engine.approvalDetails = [first.id: first]
        let gate = NeedsYouScopeGate()
        owner.response = { request in await gate.wait(); return .recorded(request) }
        let sut = repository(engine, owner: owner)
        await sut.runPass()
        let item = try #require(sut.snapshot.items.first)
        let oldResponse = Task { await sut.respond(item, decision: "approve") }
        await waitUntil { gate.isWaiting }
        // when
        owner.select("B")
        let second = approval(command: "runtime-B")
        engine.approvalRows["t1"] = [second]
        engine.approvalDetails = [second.id: second]
        await sut.runPass()
        gate.release()
        #expect(await oldResponse.value == .accepted)
        // then
        #expect(sut.snapshot.items.first?.approval == second)
        await sut.runPass()
        #expect(sut.snapshot.items.count == 1)
        #expect(sut.snapshot.items.first?.approval == second)
    }

    @Test func givenUnchangedEngineSnapshot_whenSharedEvidenceChanges_thenSubscribersSeeBusyRecoveryAndUncertaintyWithStableCounts() async {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let request = approval()
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [request]
        engine.approvalDetails = [request.id: request]
        let sut = repository(engine, owner: owner)
        let observed = LockedBox<[NeedsYouSnapshot]>([])
        let subscription = sut.snapshotPublisher().sink { snapshot in observed.mutate { $0.append(snapshot) } }
        await sut.runPass()
        let baseline = observed.value.count
        // when
        owner.evidence.mutate { $0 = .busy }
        await sut.runPass()
        await sut.runPass() // Equal owner/engine facts remain quiet.
        #expect(observed.value.count == baseline + 1)
        #expect(observed.value.last?.items.first?.approvalOutcome == .busy)
        owner.evidence.mutate { $0 = nil }
        await sut.runPass()
        #expect(observed.value.count == baseline + 2)
        #expect(observed.value.last?.items.first?.approvalCanRespond == true)
        owner.evidence.mutate { $0 = .uncertain }
        await sut.runPass()
        // then
        #expect(observed.value.count == baseline + 3)
        #expect(observed.value.last?.items.first?.approvalOutcome == .uncertain)
        #expect(observed.value.last?.items.first?.approvalCanRespond == false)
        #expect(observed.value.suffix(4).allSatisfy { $0.items.count == 1 })
        subscription.cancel()
    }

    private func repository(_ engine: FakeNeedsYouEngine, owner: NeedsYouScopeOwner) -> NeedsYouRepositoryImpl {
        NeedsYouRepositoryImpl(engine: engine, toolEnvironment: NullToolEnvironmentRepository(), scheduler: CapturingScheduler(),
                               visibility: FakeMonitorVisibility(), install: readyInstall(), approvals: owner)
    }
}

// MARK: - NeedsYouScopeOwner

private final class NeedsYouScopeOwner: ApprovalResponding, @unchecked Sendable {
    private let selected = LockedBox(NeedsYouScopeOwner.makeContext("A"))
    let evidence = LockedBox<ApprovalResponseOutcome?>(nil)
    var response: (@Sendable (CallerApprovalRequest) async -> ApprovalResponseOutcome)?
    func context() throws -> ApprovalResponseContext { selected.value }
    func isCurrent(_ context: ApprovalResponseContext) -> Bool { selected.value == context }
    func retained(_: CallerApprovalRequest, context _: ApprovalResponseContext) -> ApprovalResponseOutcome? { evidence.value }
    func respond(_ request: CallerApprovalRequest, decision _: String, context _: ApprovalResponseContext) async -> ApprovalResponseOutcome {
        if let response { return await response(request) }
        return .uncertain
    }

    func select(_ name: String) { selected.mutate { $0 = Self.makeContext(name) } }
    private static func makeContext(_ name: String) -> ApprovalResponseContext {
        ApprovalResponseContext(
            runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl", environment: ["TEST_RUNTIME": name])), epoch: UUID()
        )
    }
}

// MARK: - NeedsYouScopeGate

private final class NeedsYouScopeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    var isWaiting: Bool { lock.withLock { waiter != nil } }
    func wait() async { await withCheckedContinuation { continuation in lock.withLock { waiter = continuation } } }
    func release() {
        let held = lock.withLock { let held = waiter; waiter = nil; return held }
        held?.resume()
    }
}
