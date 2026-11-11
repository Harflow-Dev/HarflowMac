import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - ScriptedUseCase

/// Records every owner call, can hold checks and recorded-status calls open, and flags overlapping calls.
@MainActor
private final class ScriptedUseCase: PendingLaunchesUseCase {
    let subject: CurrentValueSubject<PendingLaunchSnapshot, Never>
    var offered: PendingLaunchReadLease?
    var holdCalls = false
    var lookupFor: (PendingLaunchSelection) -> PendingLaunchLookup?
    var resolveResult: PendingLaunchRecordedResult = .failed(.unavailable)
    var resolveStores: (PendingLaunchSelection) -> PendingLaunchLookup? = { _ in nil }
    private(set) var acquisitions = 0
    private(set) var binds: [(taskID: String?, lease: PendingLaunchReadLease)] = []
    private(set) var checks: [PendingLaunchSelection] = []
    private(set) var resolves: [PendingLaunchSelection] = []
    private(set) var cancelled = 0
    private(set) var overlapped = false
    private var inFlight = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(snapshot: PendingLaunchSnapshot, lease: PendingLaunchReadLease?) {
        self.subject = CurrentValueSubject(snapshot)
        self.offered = lease
        self.lookupFor = { ScriptedUseCase.pending($0) }
    }

    static func pending(_ selection: PendingLaunchSelection) -> PendingLaunchLookup {
        PendingLaunchLookup(selection: selection, value: PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: selection.taskID)), failure: nil)
    }

    static func recorded(_ selection: PendingLaunchSelection) -> PendingLaunchLookup {
        PendingLaunchLookup(selection: selection, value: PendingLaunchesFixture.plainLookup(id: selection.taskID, disposition: "recorded"), failure: nil)
    }

    /// When set, the synchronous snapshot diverges from what the publisher has delivered.
    var syncSnapshot: PendingLaunchSnapshot?
    var snapshot: PendingLaunchSnapshot { syncSnapshot ?? subject.value }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { subject.eraseToAnyPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? {
        acquisitions += 1
        return offered
    }

    var released: [PendingLaunchReadLease] = []
    func releaseReadLease(_ lease: PendingLaunchReadLease) { released.append(lease) }
    func refresh(lease _: PendingLaunchReadLease) async {}

    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection? {
        binds.append((taskID, lease))
        return taskID.map { PendingLaunchSelection(taskID: $0, lease: lease) }
    }

    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        checks.append(selection)
        await enter()
        defer { inFlight -= 1 }
        guard let lookup = lookupFor(selection) else { return PendingLaunchLookup(selection: selection, value: nil, failure: .busy) }
        store(lookup)
        return lookup
    }

    func resolveRecorded(selection: PendingLaunchSelection) async -> PendingLaunchRecordedResult {
        resolves.append(selection)
        await enter()
        defer { inFlight -= 1 }
        if let lookup = resolveStores(selection) { store(lookup) }
        return resolveResult
    }

    func prepareStop(selection _: PendingLaunchSelection) async -> PendingLaunchStopPreparation { .failed(.unavailable) }
    func submitStop(confirmation _: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission { .refused(.unavailable) }

    private func enter() async {
        inFlight += 1
        if inFlight > 1 { overlapped = true }
        if holdCalls { await withCheckedContinuation { waiting.append($0) } }
        if Task.isCancelled { cancelled += 1 }
    }

    func releaseHeld() {
        holdCalls = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }

    private func store(_ lookup: PendingLaunchLookup) {
        var next = subject.value
        next.lookups = next.lookups.filter { $0.selection.lease != lookup.selection.lease } + [lookup]
        subject.send(next)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func add(_ value: String) { lock.withLock { stored.append(value) } }
}

// MARK: - PendingLaunchesDetailVMTests

@MainActor @Suite
struct PendingLaunchesDetailVMTests {
    private let idA = "20261110-093000-a17c92"
    private let idB = "20261110-093200-b28d03"

    private struct Rig {
        let useCase: ScriptedUseCase
        let routing: MockPendingLaunchesRouting
        let routed: Counter
        let sut: PendingLaunchesVM
        let lease: PendingLaunchReadLease
    }

    private func rig(lease: PendingLaunchReadLease? = PendingLaunchReadLease(), recorded: Bool = false) -> Rig {
        let rows = [PendingLaunchesFixture.item(id: idA), PendingLaunchesFixture.item(id: idB, state: "claimed")]
        let useCase = ScriptedUseCase(snapshot: .init(inventory: .init(rows: rows, completedCheck: true)), lease: lease)
        if recorded { useCase.lookupFor = { ScriptedUseCase.recorded($0) } }
        let routed = Counter()
        let routing = MockPendingLaunchesRouting()
        given(routing).openRecordedTask(.any).willProduce { routed.add($0) }
        let sut = PendingLaunchesVM(useCase: useCase, routing: routing)
        return Rig(useCase: useCase, routing: routing, routed: routed, sut: sut, lease: lease ?? PendingLaunchReadLease())
    }

    private func appeared(_ rig: Rig) async {
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.kind == .inventory }
    }

    private func drainMain() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    // MARK: - Selection

    @Test func givenInventory_whenRowSelected_thenBindsSynchronouslyShowsPlaceholderThenStoredLookup() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.holdCalls = true
        // when
        rig.sut.didSelectRow(idA)
        // then: bound and shown before any await.
        #expect(rig.useCase.binds.count == 1)
        #expect(rig.useCase.binds.first?.taskID == idA)
        #expect(rig.sut.detail?.kind == .checking)
        await waitUntil { rig.useCase.checks.count == 1 }
        #expect(rig.sut.detail?.kind == .checking)
        #expect(rig.sut.detail?.action == nil)
        rig.useCase.releaseHeld()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        #expect(rig.sut.detail?.kind == .waiting)
        #expect(rig.sut.detail?.facts.first?.value == idA)
    }

    @Test func givenNoLease_whenRowSelected_thenReacquiresBeforeBinding() async {
        // given
        let rig = rig(lease: nil)
        rig.sut.didAppear()
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.presentation.kind == .failed }
        // when: the owner still refuses.
        rig.sut.didSelectRow(idA)
        // then
        #expect(rig.sut.detail == nil)
        #expect(rig.useCase.binds.isEmpty)
        // when: the owner now accepts the interest.
        let lease = PendingLaunchReadLease()
        rig.useCase.offered = lease
        rig.sut.didSelectRow(idA)
        // then
        #expect(rig.useCase.binds.map(\.lease) == [lease])
        #expect(rig.sut.detail != nil)
    }

    @Test func givenUnlistedRow_whenSelected_thenNothingHappens() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        // when
        rig.sut.didSelectRow("20261110-999999-ffffff")
        // then
        #expect(rig.sut.detail == nil)
        #expect(rig.useCase.binds.isEmpty)
    }

    @Test func givenSelectedLaunch_whenBack_thenUnbindsSynchronouslyAndFocusesTheRow() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // when
        rig.sut.didTapBack()
        // then
        #expect(rig.useCase.binds.last?.taskID == nil)
        #expect(rig.useCase.binds.count == 2)
        #expect(rig.sut.detail == nil)
        #expect(rig.sut.focusRowID == idA)
        #expect(rig.sut.presentation.kind == .inventory)
    }

    // MARK: - Serialization

    @Test func givenCheckHeldOpen_whenBackAndReselect_thenSecondCheckRunsAfterTheFirstWithoutCancellation() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.holdCalls = true
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.useCase.checks.count == 1 }
        // when
        rig.sut.didTapBack()
        rig.sut.didSelectRow(idB)
        // then: B is queued behind A, which is still parked in the owner.
        #expect(rig.sut.activeOperations == 2)
        #expect(rig.useCase.checks.count == 1)
        rig.useCase.releaseHeld()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        #expect(rig.useCase.checks.map(\.taskID) == [idA, idB])
        #expect(!rig.useCase.overlapped)
        #expect(rig.useCase.cancelled == 0)
        #expect(rig.sut.detail?.facts.first?.value == idB)
    }

    @Test func givenInFlightCheck_whenCheckAgainTapped_thenActionIsDisabledAndIgnored() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting && rig.sut.detail?.isActionEnabled == true }
        rig.useCase.holdCalls = true
        // when
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.useCase.checks.count == 2 }
        await waitUntil { rig.sut.detail?.isActionEnabled == false }
        rig.sut.didTapDetailCheckAgain()
        rig.useCase.releaseHeld()
        await waitUntil { rig.sut.detail?.isActionEnabled == true }
        // then
        #expect(rig.useCase.checks.count == 2)
        #expect(!rig.useCase.overlapped)
    }

    // MARK: - Recorded handoff

    private func recordedRig() async -> Rig {
        let rig = rig(recorded: true)
        await appeared(rig)
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .recorded && rig.sut.detail?.isActionEnabled == true }
        return rig
    }

    private func info(_ id: String) -> TaskInfo {
        TaskInfo(.object(["task_id": .string(id), "status": .string("running")]))!
    }

    @Test func givenRecordedLaunch_whenAdmitted_thenRoutesTheSelectedIDOnce() async {
        // given
        let rig = await recordedRig()
        defer { rig.sut.didDisappear() }
        rig.useCase.resolveResult = .admitted(info(idA))
        // when
        rig.sut.didTapCheckTaskStatus()
        await waitUntil { !rig.routed.values.isEmpty }
        await rig.sut.lastOperation?.value
        // then
        #expect(rig.routed.values == [idA])
    }

    @Test func givenAdmittedDifferentID_whenResolved_thenNoRouteAndHandoffFailed() async {
        // given
        let rig = await recordedRig()
        defer { rig.sut.didDisappear() }
        rig.useCase.resolveResult = .admitted(info(idB))
        // when
        rig.sut.didTapCheckTaskStatus()
        await waitUntil { rig.sut.detail?.kind == .handoffFailed }
        // then
        #expect(rig.routed.values.isEmpty)
    }

    @Test func givenInertFailures_whenResolved_thenNothingIsRecordedAsHandoffFailure() async {
        // given
        let rig = await recordedRig()
        defer { rig.sut.didDisappear() }
        for failure in [PendingLaunchFailure.busy, .capacity, .superseded] {
            rig.useCase.resolveResult = .failed(failure)
            let before = rig.useCase.resolves.count
            // when
            rig.sut.didTapCheckTaskStatus()
            await waitUntil { rig.useCase.resolves.count == before + 1 && rig.sut.detail?.isActionEnabled == true }
            // then
            #expect(rig.sut.detail?.kind == .recorded, "\(failure)")
        }
        #expect(rig.routed.values.isEmpty)
    }

    @Test func givenStatusOrAdmissionFailure_whenResolved_thenHandoffFailedWithCheckAgain() async {
        // given
        let failures: [PendingLaunchFailure] = [.tool(.refused(code: "x", message: "y")), .recordedAdmission(.cycle)]
        for failure in failures {
            let rig = await recordedRig()
            rig.useCase.resolveResult = .failed(failure)
            // when
            rig.sut.didTapCheckTaskStatus()
            await waitUntil { rig.sut.detail?.kind == .handoffFailed }
            // then
            #expect(rig.sut.detail?.kind == .handoffFailed, "\(failure)")
            #expect(rig.sut.detail?.action == .checkAgain)
            #expect(rig.routed.values.isEmpty)
            rig.sut.didDisappear()
        }
    }

    @Test func givenChangedResult_whenResolved_thenDetailFollowsTheStoredLookup() async {
        // given
        let rig = await recordedRig()
        defer { rig.sut.didDisappear() }
        rig.useCase.resolveResult = .failed(.changed)
        rig.useCase.resolveStores = { ScriptedUseCase.pending($0) }
        // when
        rig.sut.didTapCheckTaskStatus()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // then
        #expect(rig.sut.detail?.kind == .waiting)
        #expect(rig.routed.values.isEmpty)
    }

    @Test func givenHandoffFailure_whenCheckAgainStarts_thenFailureClearsEvenIfTheNextLookupIsEqual() async {
        // given
        let rig = await recordedRig()
        defer { rig.sut.didDisappear() }
        rig.useCase.resolveResult = .failed(.tool(.refused(code: "x", message: "y")))
        rig.sut.didTapCheckTaskStatus()
        await waitUntil { rig.sut.detail?.kind == .handoffFailed && rig.sut.detail?.isActionEnabled == true }
        rig.useCase.holdCalls = true
        // when
        rig.sut.didTapDetailCheckAgain()
        // then: cleared at action start, while the check is still held and the stored lookup is unchanged.
        await waitUntil { rig.sut.detail?.kind == .recorded }
        #expect(rig.sut.detail?.kind == .recorded)
        rig.useCase.releaseHeld()
    }

    private enum Interruption: CaseIterable {
        case back, disappear, disappearAndReappear, runtimeChange, reselect
    }

    @Test func givenAdmittedResultArrivesLate_whenTheScreenMovedOn_thenItNeverRoutes() async {
        for interruption in Interruption.allCases {
            // given
            let rig = await recordedRig()
            rig.useCase.resolveResult = .admitted(info(idA))
            rig.useCase.holdCalls = true
            rig.sut.didTapCheckTaskStatus()
            await waitUntil { rig.useCase.resolves.count == 1 }
            let pending = rig.sut.lastOperation
            // when
            switch interruption {
            case .back: rig.sut.didTapBack()
            case .disappear: rig.sut.didDisappear()
            case .disappearAndReappear:
                rig.sut.didDisappear()
                rig.sut.didAppear()
            case .runtimeChange:
                var next = rig.useCase.subject.value
                next.runtimeIdentity = UUID()
                rig.useCase.subject.send(next)
                await waitUntil { rig.sut.detail == nil }
            case .reselect:
                rig.sut.didTapBack()
                rig.sut.didSelectRow(idA)
            }
            rig.useCase.releaseHeld()
            await pending?.value
            await rig.sut.lastOperation?.value
            // then
            #expect(rig.routed.values.isEmpty, "\(interruption)")
            rig.sut.didDisappear()
        }
    }

    private enum RoutingGuard: CaseIterable {
        case subscribed, selection, runtimeIdentity, epoch
    }

    @Test func givenAdmittedResult_whenAnySingleRoutingGuardFails_thenItNeverRoutes() async {
        for failing in RoutingGuard.allCases {
            // given
            let rig = await recordedRig()
            rig.useCase.resolveResult = .admitted(info(idA))
            rig.useCase.holdCalls = true
            rig.sut.didTapCheckTaskStatus()
            await waitUntil { rig.useCase.resolves.count == 1 }
            let pending = rig.sut.lastOperation
            // when: only one condition changes, and the publisher has not delivered anything.
            switch failing {
            case .subscribed: rig.sut.didSubscribe = false
            case .selection: rig.sut.selection = PendingLaunchSelection(taskID: idA, lease: rig.lease)
            case .runtimeIdentity:
                var next = rig.useCase.subject.value
                next.runtimeIdentity = UUID()
                rig.useCase.syncSnapshot = next
            case .epoch: rig.sut.epoch += 1
            }
            rig.useCase.releaseHeld()
            await pending?.value
            // then
            #expect(rig.routed.values.isEmpty, "\(failing)")
            rig.sut.didSubscribe = true
            rig.sut.didDisappear()
        }
    }

    @Test func givenStaleSnapshotDeliveredAfterCheckReturned_whenItArrives_thenTheStoredLookupStillShows() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        let before = rig.useCase.subject.value
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting && rig.sut.detail?.isActionEnabled == true }
        // The synchronous snapshot carries a real change, so a build is guaranteed to follow the delivery.
        var current = rig.useCase.subject.value
        current.inventory.isStale = true
        rig.useCase.syncSnapshot = current
        let processed = Counter()
        rig.sut.didProcessBuild = { _ in processed.add("build") }
        // when: the owner's drain delivers a value older than the synchronous snapshot.
        rig.useCase.subject.send(before)
        await waitUntil { !processed.values.isEmpty }
        await rig.sut.lastOperation?.value
        // then
        #expect(rig.sut.detail?.kind == .waiting)
    }

    // MARK: - Lifecycle

    @Test func givenSelectedLaunch_whenViewDisappearsAndReappears_thenInventoryIsShownWithoutRestore() async {
        // given
        let rig = rig()
        await appeared(rig)
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // when
        rig.sut.didDisappear()
        #expect(rig.sut.detail == nil)
        rig.sut.didAppear()
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.presentation.kind == .inventory }
        // then
        #expect(rig.sut.detail == nil)
        #expect(rig.useCase.released == [rig.lease])
    }

    @Test func givenSelectedLaunch_whenRuntimeIdentityChanges_thenInventoryIsShown() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // when
        var next = rig.useCase.subject.value
        next.runtimeIdentity = UUID()
        next.inventory = .init()
        rig.useCase.subject.send(next)
        await waitUntil { rig.sut.detail == nil }
        // then
        #expect(rig.sut.detail == nil)
    }

    @Test func givenSelectedLaunch_whenOnlyOtherLeasesLookupsChange_thenNothingRebuilds() async {
        // given
        let builds = Counter()
        let rig = rig()
        let sut = PendingLaunchesVM(useCase: rig.useCase, routing: rig.routing, builder: { input in
            builds.add("build")
            return PendingLaunchesBuildOutput.make(input)
        })
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.kind == .inventory }
        sut.didSelectRow(idA)
        await waitUntil { sut.detail?.kind == .waiting && sut.detail?.isActionEnabled == true }
        await drainMain()
        let baseline = builds.values.count
        // when
        var next = rig.useCase.subject.value
        let foreign = PendingLaunchSelection(taskID: idB, lease: PendingLaunchReadLease())
        next.lookups.append(ScriptedUseCase.pending(foreign))
        rig.useCase.subject.send(next)
        await drainMain()
        // then
        #expect(builds.values.count == baseline)
    }
}
