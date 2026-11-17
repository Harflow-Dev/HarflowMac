import Combine
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
        #expect(sut.snapshot.workflowContext == WorkflowResponseContext(runtime: try owner.context().runtime, epoch: try owner.context().epoch))
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

    @Test func givenWorkflowWithoutRuntimeObservation_whenAnswered_thenRefusesBeforeAnyMutation() async throws {
        // given
        let engine = workflowEngine()
        let sut = NeedsYouRepositoryImpl(engine: engine, toolEnvironment: NullToolEnvironmentRepository(), scheduler: CapturingScheduler(),
                                        visibility: FakeMonitorVisibility(), install: readyInstall())
        await sut.runPass()
        let shown = try #require(sut.snapshot.items.first)
        // when
        let result = await sut.answer(shown, text: "answer", additionalAttempts: nil)
        // then
        #expect(result == .stale(NeedsYouAnswerOutcome.changedMessage))
        #expect(engine.resumes.isEmpty)
    }

    @Test(arguments: [false, true])
    func givenDisplayedWorkflowA_whenRuntimeChangesWithCopiedIDs_thenOldRequestCannotSend(returnToA: Bool) async throws {
        // given
        let engine = workflowEngine()
        let owner = NeedsYouScopeOwner()
        let sut = repository(engine, owner: owner)
        await sut.runPass()
        let shown = try #require(sut.snapshot.items.first)
        // when — even an unobserved B→A selection revokes the displayed epoch.
        owner.select("B")
        if returnToA { owner.select("A") }
        let result = await sut.answer(shown, text: "answer", additionalAttempts: nil)
        // then
        #expect(result == .stale(NeedsYouAnswerOutcome.changedMessage))
        #expect(engine.resumes.isEmpty)
        await sut.runPass()
        #expect(sut.snapshot.items.first?.workflowContext != shown.workflowContext)
    }

    @Test func givenSuspendedWorkflowSubmit_whenRuntimeEpochChanges_thenNoMutationStarts() async throws {
        // given
        let engine = workflowEngine()
        let owner = NeedsYouScopeOwner()
        let sut = repository(engine, owner: owner)
        await sut.runPass()
        let shown = try #require(sut.snapshot.items.first)
        let gate = NeedsYouScopeGate()
        engine.resumeRead = { await gate.wait() }
        let response = Task { await sut.answer(shown, text: "answer", additionalAttempts: nil) }
        await waitUntil { gate.isWaiting }
        // when
        owner.select("B")
        owner.select("A")
        gate.release()
        _ = await response.value
        // then
        #expect(engine.resumes.isEmpty)
        #expect(sut.snapshot.items.count == 1)
    }

    @Test func givenInvokedWorkflowA_whenSameIDBPublishesBeforeCompletion_thenOldSettlementCannotSuppressB() async throws {
        // given
        let engine = workflowEngine()
        let owner = NeedsYouScopeOwner()
        let sut = repository(engine, owner: owner)
        await sut.runPass()
        let shown = try #require(sut.snapshot.items.first)
        let gate = NeedsYouScopeGate()
        engine.resumeCompletion = { await gate.wait() }
        let response = Task { await sut.answer(shown, text: "answer", additionalAttempts: nil) }
        await waitUntil { gate.isWaiting }
        // when
        owner.select("B")
        await sut.runPass()
        let replacement = try #require(sut.snapshot.items.first)
        gate.release()
        #expect(await response.value == .accepted)
        await sut.runPass()
        // then
        #expect(sut.snapshot.items.first == replacement)
        #expect(replacement.workflowContext != shown.workflowContext)
    }

    @Test func givenEmptyInventory_whenRuntimeChangesAndReturns_thenEverySnapshotRetainsItsCapturedObservation() async throws {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let sut = repository(engine, owner: owner)
        let observed = LockedBox<[NeedsYouSnapshot]>([])
        let subscription = sut.snapshotPublisher().sink { value in observed.mutate { $0.append(value) } }
        await sut.runPass()
        let first = try #require(sut.snapshot.workflowContext)
        // when
        owner.select("B")
        await sut.runPass()
        let second = try #require(sut.snapshot.workflowContext)
        owner.select("A")
        await sut.runPass()
        let returned = try #require(sut.snapshot.workflowContext)
        // then — empty/loading publications carry provenance independently of item identity.
        #expect(first != second && first != returned && second != returned)
        #expect(first.runtime == returned.runtime)
        let allInventoriesAreEmpty = observed.value.allSatisfy(\.items.isEmpty)
        #expect(allInventoriesAreEmpty)
        for context in [first, second, returned] {
            #expect(observed.value.contains { $0.phase == .loading && $0.workflowContext == context })
            #expect(observed.value.contains { $0.phase == .ready && $0.workflowContext == context })
        }
        subscription.cancel()
    }

    @Test func givenSuspendedPass_whenQualificationIsLost_thenResetRetiresScopeAndLateOutputCannotRestoreIt() async throws {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let state = CurrentValueSubject<RuntimeSetupState, Never>(.ready)
        let request = approval(command: "runtime-A")
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [request]
        let gate = NeedsYouScopeGate()
        engine.approvalDetailRead = { _, _ in await gate.wait(); return request }
        let sut = NeedsYouRepositoryImpl(engine: engine, toolEnvironment: NullToolEnvironmentRepository(), scheduler: CapturingScheduler(),
                                        visibility: FakeMonitorVisibility(), install: readyInstall(state), approvals: owner)
        let observed = LockedBox<[NeedsYouSnapshot]>([])
        let subscription = sut.snapshotPublisher().sink { value in observed.mutate { $0.append(value) } }
        let oldPass = Task { await sut.runPass() }
        await waitUntil { gate.isWaiting }
        #expect(sut.snapshot.workflowContext != nil)
        // when — keep owner.context current to prove qualification reset has its own retirement fence.
        state.send(.checking)
        await sut.runPass()
        let resetCount = observed.value.count
        #expect(sut.snapshot == NeedsYouSnapshot())
        state.send(.ready)
        gate.release()
        await oldPass.value
        // then — even requalification with the same owner context cannot revive the retired actor.
        #expect(sut.snapshot == NeedsYouSnapshot())
        #expect(observed.value.count == resetCount)
        #expect(observed.value.last?.workflowContext == nil)
        engine.approvalDetailRead = nil
        engine.approvalDetails = [request.id: request]
        await sut.runPass()
        #expect(sut.snapshot.items.first?.approval == request)
        #expect(sut.snapshot.workflowContext != nil)
        subscription.cancel()
    }

    @Test func givenStartedLoopWithSuspendedRead_whenQualificationIsLost_thenSnapshotResetsBeforeReadReturns() async {
        // given
        let engine = FakeNeedsYouEngine()
        let owner = NeedsYouScopeOwner()
        let state = CurrentValueSubject<RuntimeSetupState, Never>(.ready)
        let request = approval(command: "retired-pass")
        engine.tasks = [awaitingTask("t1")]
        engine.approvalRows["t1"] = [request]
        let oldRead = NeedsYouScopeGate()
        let newRead = NeedsYouScopeGate()
        let calls = LockedBox(0)
        engine.approvalDetailRead = { _, _ in
            var first = false
            calls.mutate { $0 += 1; first = $0 == 1 }
            if first { await oldRead.wait() } else { await newRead.wait() }
            return request
        }
        let sut = NeedsYouRepositoryImpl(engine: engine, toolEnvironment: NullToolEnvironmentRepository(), scheduler: CapturingScheduler(),
                                        visibility: FakeMonitorVisibility(), install: readyInstall(state), approvals: owner)
        let observed = LockedBox<[NeedsYouSnapshot]>([])
        let subscription = sut.snapshotPublisher().sink { value in observed.mutate { $0.append(value) } }
        sut.start()
        sut.start() // Subscription admission stays idempotent outside the state lock.
        await waitUntil { oldRead.isWaiting }
        #expect(sut.snapshot.workflowContext != nil)
        // when — no second runPass call, scheduler tick or completion of the old read.
        state.send(.checking)
        #expect(oldRead.isWaiting)
        #expect(sut.snapshot == NeedsYouSnapshot())
        let resetCount = observed.value.count
        state.send(.ready)
        oldRead.release()
        await waitUntil { newRead.isWaiting }
        // then — only replacement loading state may follow the reset, never the retired ready output.
        #expect(observed.value.dropFirst(resetCount).allSatisfy { $0.items.isEmpty && $0.phase == .loading })
        #expect(sut.snapshot.items.isEmpty)
        state.send(.checking)
        newRead.release()
        subscription.cancel()
    }

    private func workflowEngine() -> FakeNeedsYouEngine {
        let engine = FakeNeedsYouEngine()
        engine.headers = [rootHeader("w1")]
        engine.statuses["w1"] = treeRoot("w1", selected: "d1", inputs: [inputEntry(run: "w1", decision: "d1")])
        return engine
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
            runtime: QualificationRuntimeToken(client: CtlClient(executable: "/fixture/ctl",
                                                                environment: ["TEST_RUNTIME": name, "HOME": "/fixture/" + name])), epoch: UUID()
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
