import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

private final class CountingBox<Value: Sendable>: @unchecked Sendable {
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

    private func makeUseCase(
        snapshot: PendingLaunchSnapshot = .init(), lease: PendingLaunchReadLease? = PendingLaunchReadLease(),
        offered: CountingBox<PendingLaunchReadLease?>? = nil, refreshes: CountingBox<[PendingLaunchReadLease]>? = nil
    ) -> (MockPendingLaunchesUseCase, CurrentValueSubject<PendingLaunchSnapshot, Never>) {
        let offered = offered ?? CountingBox(lease)
        let refreshes = refreshes ?? CountingBox([])
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
        let offered = CountingBox<PendingLaunchReadLease?>(nil)
        let refreshes = CountingBox<[PendingLaunchReadLease]>([])
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
        let refreshes = CountingBox<[PendingLaunchReadLease]>([])
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
        await waitUntil(timeout: 0.3) { sut.presentation.kind == .empty }

        // then
        #expect(sut.presentation == .loading)
    }
}
