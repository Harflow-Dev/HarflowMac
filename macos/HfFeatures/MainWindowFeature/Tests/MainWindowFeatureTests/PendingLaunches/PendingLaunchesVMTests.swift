import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

private final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { self.stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

@MainActor @Suite
struct PendingLaunchesVMTests {
    private let rows = [PendingLaunchesFixture.item(id: "20261110-093000-a17c92")]

    private func makeSUT(
        _ useCase: MockPendingLaunchesUseCase, builds: LockedValue<[PendingLaunchesProjection]>? = nil,
        gate: (@Sendable (PendingLaunchesProjection) async -> Void)? = nil
    ) -> PendingLaunchesVM {
        PendingLaunchesVM(useCase: useCase, builder: { input in
            builds?.value.append(input.projection)
            await gate?(input.projection)
            return PendingLaunchesBuildOutput.make(input)
        })
    }

    /// Lets queued main-actor continuations (including cancelled-build epilogues) run.
    private func drainMain() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    private func makeUseCase(
        snapshot: PendingLaunchSnapshot = .init(), lease: PendingLaunchReadLease? = PendingLaunchReadLease(),
        offered: LockedValue<PendingLaunchReadLease?>? = nil, refreshes: LockedValue<[PendingLaunchReadLease]>? = nil
    ) -> (MockPendingLaunchesUseCase, CurrentValueSubject<PendingLaunchSnapshot, Never>) {
        let offered = offered ?? LockedValue(lease)
        let refreshes = refreshes ?? LockedValue([])
        let subject = CurrentValueSubject<PendingLaunchSnapshot, Never>(snapshot)
        let useCase = MockPendingLaunchesUseCase()
        given(useCase).snapshot.willProduce { subject.value }
        given(useCase).snapshotPublisher().willReturn(subject.eraseToAnyPublisher())
        given(useCase).acquireReadLease().willProduce { offered.value }
        given(useCase).releaseReadLease(.any).willReturn(())
        given(useCase).refresh(lease: .any).willProduce { refreshes.value.append($0) }
        return (useCase, subject)
    }

    private func snapshot(identity: UUID = UUID(), inventory: PendingLaunchInventory) -> PendingLaunchSnapshot {
        .init(runtimeIdentity: identity, inventory: inventory)
    }

    @Test func givenNewVM_whenCreated_thenNothingIsAcquired() {
        // given / when
        let (useCase, _) = makeUseCase()
        let sut = PendingLaunchesVM(useCase: useCase)
        // then
        #expect(sut.presentation == .loading)
        verify(useCase).acquireReadLease().called(0)
    }

    @Test func givenAppearance_whenSnapshotCompletes_thenLeaseAcquiredOnceAndPresentationFollows() async {
        // given
        let (useCase, subject) = makeUseCase()
        let sut = PendingLaunchesVM(useCase: useCase)
        // when
        sut.didAppear()
        sut.didAppear()
        defer { sut.didDisappear() }
        subject.send(snapshot(identity: subject.value.runtimeIdentity, inventory: .init(rows: rows, completedCheck: true)))
        await waitUntil { sut.presentation.kind == .inventory }
        // then
        #expect(sut.presentation.kind == .inventory)
        verify(useCase).acquireReadLease().called(1)
    }

    @Test func givenHeldLease_whenDisappearingTwice_thenReleasedOnceAndReappearanceAcquiresAgain() {
        // given
        let lease = PendingLaunchReadLease()
        let (useCase, _) = makeUseCase(lease: lease)
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        // when
        sut.didDisappear()
        sut.didDisappear()
        // then
        verify(useCase).releaseReadLease(.value(lease)).called(1)
        // when
        sut.didAppear()
        defer { sut.didDisappear() }
        // then
        verify(useCase).acquireReadLease().called(2)
    }

    @Test func givenRefusedLease_whenAppearing_thenFailedUntilCheckAgainReacquires() async {
        // given
        let offered = LockedValue<PendingLaunchReadLease?>(nil)
        let refreshes = LockedValue<[PendingLaunchReadLease]>([])
        let (useCase, _) = makeUseCase(offered: offered, refreshes: refreshes)
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.kind == .failed }
        #expect(sut.presentation.kind == .failed)
        #expect(sut.presentation.checkAction == .enabled)

        // when: the owner now accepts the interest.
        offered.value = PendingLaunchReadLease()
        sut.didTapCheckAgain()
        await waitUntil { sut.presentation.kind == .loading }

        // then: acquisition itself starts the read, so no separate refresh is requested.
        #expect(sut.presentation.kind == .loading)
        #expect(refreshes.value.isEmpty)
    }

    @Test func givenHeldLeaseAndEnabledAction_whenCheckAgain_thenRefreshesWithThatLease() async {
        // given
        let lease = PendingLaunchReadLease()
        let refreshes = LockedValue<[PendingLaunchReadLease]>([])
        let (useCase, _) = makeUseCase(snapshot: snapshot(inventory: .init(rows: rows, completedCheck: true)),
                                       lease: lease, refreshes: refreshes)
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.checkAction == .enabled }

        // when
        sut.didTapCheckAgain()
        await waitUntil { !refreshes.value.isEmpty }

        // then
        #expect(refreshes.value == [lease])
    }

    @Test func givenRefreshInProgress_whenCheckAgain_thenNothingIsRequested() async {
        // given
        let (useCase, _) = makeUseCase(snapshot: snapshot(inventory: .init(rows: rows, isRefreshing: true, completedCheck: true)))
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.kind == .inventory }

        // when
        sut.didTapCheckAgain()

        // then
        #expect(sut.presentation.checkAction == .disabled)
        verify(useCase).refresh(lease: .any).called(0)
    }

    @Test func givenRapidSnapshots_whenDelivered_thenLatestPresentationWins() async {
        // given
        let (useCase, subject) = makeUseCase()
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        let identity = subject.value.runtimeIdentity

        // when
        subject.send(snapshot(identity: identity, inventory: .init(rows: rows, completedCheck: true)))
        subject.send(snapshot(identity: identity, inventory: .init(completedCheck: true)))
        await waitUntil { sut.presentation.kind == .empty }

        // then
        #expect(sut.presentation.kind == .empty)
    }

    @Test func givenRuntimeIdentityChange_whenOwnerResetsInventory_thenPresentationFollowsToLoading() async {
        // given
        let identity = UUID()
        let (useCase, subject) = makeUseCase(snapshot: snapshot(identity: identity, inventory: .init(rows: rows, completedCheck: true)))
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.kind == .inventory }

        // when
        subject.send(snapshot(identity: UUID(), inventory: .init()))
        await waitUntil { sut.presentation.kind == .loading }

        // then
        #expect(sut.presentation == .loading)
    }

    @Test func givenDisappeared_whenSnapshotArrives_thenPresentationIsNotUpdated() async {
        // given
        let (useCase, subject) = makeUseCase()
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        sut.didDisappear()

        // when
        subject.send(snapshot(inventory: .init(completedCheck: true)))
        await drainMain()

        // then
        #expect(sut.presentation == .loading)
    }

    @Test func givenAbandonedRead_whenOwnerGoesIdleWithoutResult_thenFailedWithCheckAgain() async {
        // given
        let (useCase, subject) = makeUseCase()
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        let identity = subject.value.runtimeIdentity
        await drainMain()
        #expect(sut.presentation == .loading)

        // when: a read starts and is abandoned as superseded.
        subject.send(snapshot(identity: identity, inventory: .init(isRefreshing: true)))
        await drainMain()
        #expect(sut.presentation == .loading)
        subject.send(snapshot(identity: identity, inventory: .init()))
        await waitUntil { sut.presentation.kind == .failed }

        // then
        #expect(sut.presentation.kind == .failed)
        #expect(sut.presentation.checkAction == .enabled)
    }

    @Test func givenSnapshotsDifferingOnlyInLookupsAndAttempts_whenDelivered_thenNoRebuildHappens() async {
        // given
        let builds = LockedValue<[PendingLaunchesProjection]>([])
        let (useCase, subject) = makeUseCase()
        let sut = makeSUT(useCase, builds: builds)
        sut.didAppear()
        defer { sut.didDisappear() }
        let identity = subject.value.runtimeIdentity
        await waitUntil { !builds.value.isEmpty }
        await drainMain()
        let baseline = builds.value.count

        // when: only lookup/attempt evidence changes, then a real inventory change follows.
        var busy = snapshot(identity: identity, inventory: .init())
        busy.lookups = [PendingLaunchLookup(
            selection: PendingLaunchSelection(taskID: "20261110-093000-a17c92", lease: PendingLaunchReadLease()),
            value: nil, failure: .unavailable
        )]
        subject.send(busy)
        await drainMain()
        subject.send(snapshot(identity: identity, inventory: .init(completedCheck: true)))
        await waitUntil { sut.presentation.kind == .empty }

        // then
        #expect(builds.value.count == baseline + 1)
    }

    @Test func givenOlderBuildFinishesAfterNewerOne_whenProcessed_thenItNeverOverwritesTheNewerPresentation() async throws {
        // given: the build for a one-row inventory is held open on a continuation gate.
        let gate = BuildGate()
        let processed = LockedValue<[Bool]>([])
        let (useCase, subject) = makeUseCase()
        let sut = makeSUT(useCase, gate: { projection in
            if projection.inventory.rows.count == 1 { await gate.wait() }
        })
        sut.didProcessBuild = { processed.value.append($0) }
        sut.didAppear()
        defer { sut.didDisappear() }
        let identity = subject.value.runtimeIdentity
        subject.send(snapshot(identity: identity, inventory: .init(rows: rows, completedCheck: true)))
        await drainMain()

        // when: a newer build completes while the older one is held, then the older one is released.
        subject.send(snapshot(identity: identity, inventory: .init(completedCheck: true)))
        await waitUntil { sut.presentation.kind == .empty }
        try #require(sut.presentation.kind == .empty)
        let processedBefore = processed.value.count
        await gate.release()
        await waitUntil { processed.value.count > processedBefore }

        // then: the older result was processed, dropped, and the newer presentation stands.
        try #require(processed.value.count > processedBefore, "the older build result was never processed")
        #expect(processed.value.last == false)
        #expect(sut.presentation.kind == .empty)
    }

    @Test func givenCheckAgainTappedTwiceDuringRefresh_whenRefreshesComplete_thenNeitherIsCancelled() async throws {
        // given
        let useCase = SuspendingRefreshUseCase(snapshot: snapshot(inventory: .init(rows: rows, completedCheck: true)))
        let sut = PendingLaunchesVM(useCase: useCase)
        sut.didAppear()
        defer { sut.didDisappear() }
        await waitUntil { sut.presentation.checkAction == .enabled }
        try #require(sut.presentation.checkAction == .enabled)

        // when
        sut.didTapCheckAgain()
        await waitUntil { useCase.started == 1 }
        sut.didTapCheckAgain()
        await waitUntil { useCase.started == 2 }
        try #require(useCase.started == 2)
        useCase.releaseAll()
        await waitUntil { useCase.finished == 2 }

        // then
        try #require(useCase.finished == 2)
        #expect(useCase.cancelled == 0)
    }
}

private actor BuildGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// A use case whose refreshes suspend until released, recording whether each was cancelled.
@MainActor
private final class SuspendingRefreshUseCase: PendingLaunchesUseCase {
    private let subject: CurrentValueSubject<PendingLaunchSnapshot, Never>
    private let lease = PendingLaunchReadLease()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var started = 0
    private(set) var finished = 0
    private(set) var cancelled = 0

    init(snapshot: PendingLaunchSnapshot) { self.subject = CurrentValueSubject(snapshot) }

    var snapshot: PendingLaunchSnapshot { subject.value }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { subject.eraseToAnyPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? { lease }
    func releaseReadLease(_: PendingLaunchReadLease) {}

    func bindSelection(taskID _: String?, lease _: PendingLaunchReadLease) -> PendingLaunchSelection? { nil }
    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        PendingLaunchLookup(selection: selection, value: nil, failure: .unavailable)
    }

    func resolveRecorded(selection _: PendingLaunchSelection) async -> PendingLaunchRecordedResult { .failed(.unavailable) }

    func refresh(lease _: PendingLaunchReadLease) async {
        started += 1
        await withCheckedContinuation { waiting.append($0) }
        if Task.isCancelled { cancelled += 1 }
        finished += 1
    }

    func releaseAll() {
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }
}
