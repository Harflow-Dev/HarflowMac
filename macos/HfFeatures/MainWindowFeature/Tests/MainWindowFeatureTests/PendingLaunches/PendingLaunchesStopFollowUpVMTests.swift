import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
@testable import MonitorCore
import Testing

// MARK: - PendingLaunchesStopFollowUpVMTests

/// Preflight refreshes, acknowledgement and survival across navigation for Stop attempts.
@MainActor @Suite
struct PendingLaunchesStopFollowUpVMTests {
    private let idA = "20261110-093000-a17c92"
    private let idB = "20261110-093200-b28d03"

    private struct Rig {
        let useCase: StopScriptedUseCase
        let routing: MockPendingLaunchesRouting
        let box: RequestBox
        let sut: PendingLaunchesVM
    }

    private func rig() -> Rig {
        let useCase = StopScriptedUseCase(rows: [idA, idB])
        let box = RequestBox()
        let routing = MockPendingLaunchesRouting()
        given(routing).presentPendingLaunchStop(.any).willProduce { box.add($0) }
        given(routing).dismissPendingLaunchStop().willProduce { box.dismissed() }
        return Rig(useCase: useCase, routing: routing, box: box, sut: PendingLaunchesVM(useCase: useCase, routing: routing))
    }

    /// Selected, checked and showing an enabled Stop.
    private func ready(_ rig: Rig, id: String? = nil) async {
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.kind == .inventory }
        rig.sut.didSelectRow(id ?? idA)
        await waitUntil { rig.sut.detail?.stop == .enabled }
    }

    /// `waitUntil` never fails on a timeout, so every wait that a test depends on is asserted afterwards.
    private func until(_ what: String, _ condition: @MainActor () -> Bool) async {
        await waitUntil(condition: condition)
        #expect(condition(), "\(what)")
    }

    private func attempt(_ outcome: TaskPendingLaunchStopOutcome? = nil, failure: PendingLaunchFailure? = nil,
                         executing: Bool = false, taskID: String? = nil) -> PendingLaunchStopAttempt {
        StopFixture.attempt(executing: executing, failure: failure, outcome: outcome, taskID: taskID ?? idA)
    }

    // MARK: - Preflight changed

    @Test func givenPreflightChangedAttempt_whenDeliveredAgainOrReplacedByANewOne_thenOneRefreshPerAttempt() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let first = attempt(failure: .changed)
        let before = rig.useCase.checks.count
        // when: the attempt finishes
        rig.useCase.setAttempts([first])
        await until("first refresh queued") { rig.useCase.checks.count == before + 1 }
        await until("first refresh settled") { rig.sut.activeOperations == 0 }
        #expect(rig.sut.projection.stop?.latest.attemptID == first.id)
        // when: the same attempt is delivered again inside new snapshots
        rig.useCase.touch()
        await until("redelivery projected") { rig.sut.projection.inventory.isStale }
        rig.useCase.touch()
        await until("second redelivery projected") { !rig.sut.projection.inventory.isStale }
        await until("idle") { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.useCase.checks.count == before + 1)
        // when: a new preflight-changed attempt arrives
        let second = attempt(failure: .recorded)
        rig.useCase.setAttempts([first, second])
        await until("second attempt projected") { rig.sut.projection.stop?.latest.attemptID == second.id }
        await until("second refresh queued") { rig.useCase.checks.count == before + 2 }
        await until("idle again") { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.useCase.checks.count == before + 2)
    }

    @Test func givenPreflightChangedAttemptBeforeSelection_whenSelected_thenTheSelectionCheckCoversIt() async {
        // given: the attempt finished while its ID was not selected, and the delivery is observed.
        let rig = rig()
        rig.sut.didAppear()
        defer { rig.sut.didDisappear() }
        await until("inventory") { rig.sut.presentation.kind == .inventory }
        rig.useCase.setAttempts([attempt(failure: .changed)])
        rig.useCase.touch()
        await until("snapshot delivered") { rig.sut.projection.inventory.isStale }
        // then: an unselected ID never queues anything
        #expect(rig.useCase.checks.isEmpty)
        // when: selecting queues the selection's own check, queued after the attempt finished
        rig.sut.didSelectRow(idA)
        await until("selection check ran") { rig.useCase.checks.count == 1 && rig.sut.activeOperations == 0 }
        await until("attempt projected") { rig.sut.projection.stop != nil }
        // then: no extra refresh
        #expect(rig.useCase.checks.count == 1)
    }

    @Test func givenPreflightChangedAttempt_whenNotSubscribed_thenNoCheckIsQueued() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let before = rig.useCase.checks.count
        // when: the delivery reaches a view model that is not subscribed
        rig.sut.didSubscribe = false
        rig.useCase.setAttempts([attempt(failure: .changed)])
        rig.sut.reproject()
        await until("attempt projected") { rig.sut.projection.stop?.latest.phase == .preflightChanged }
        // then
        #expect(rig.useCase.checks.count == before)
        #expect(rig.sut.activeOperations == 0)
        rig.sut.didSubscribe = true
    }

    // MARK: - Acknowledgement

    private func resolved(_ rig: Rig) async {
        rig.useCase.setAttempts([attempt(.uncertain(StopFixture.request, cause: .receiptIdentityMismatch))])
        await waitUntil { rig.sut.detail?.kind == .stopUncertain }
    }

    @Test func givenOutcomeCard_whenCheckAgainStoresALookup_thenCardIsAcknowledged() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        await resolved(rig)
        // when
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // then
        #expect(rig.sut.detail?.stop == nil)
        #expect(rig.sut.detail?.notes == [PendingLaunchDetailPresentation.unconfirmedNote])
    }

    @Test func givenOutcomeCard_whenCheckFails_thenCardStays() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        await resolved(rig)
        rig.useCase.lookupFor = { PendingLaunchLookup(selection: $0, value: nil, failure: .unavailable) }
        // when
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.sut.detail?.kind == .stopUncertain)
    }

    @Test func givenBackAndReselect_whenOutcomeExists_thenCardShowsAgainWithoutAcknowledging() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        await resolved(rig)
        // when
        rig.sut.didTapBack()
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.sut.detail?.kind == .stopUncertain)
        #expect(rig.sut.acknowledgedAttempts.isEmpty)
    }

    @Test func givenAcknowledgement_whenDisappearAndReappear_thenKeptAndPrunedWhenAttemptLeaves() async {
        // given
        let rig = rig()
        await ready(rig)
        await resolved(rig)
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        #expect(rig.sut.acknowledgedAttempts.count == 1)
        // when
        rig.sut.didDisappear()
        rig.sut.didAppear()
        defer { rig.sut.didDisappear() }
        await waitUntil { rig.sut.presentation.kind == .inventory }
        // then
        #expect(rig.sut.acknowledgedAttempts.count == 1)
        // when: the attempt leaves the owner's snapshot
        rig.useCase.setAttempts([])
        await waitUntil { rig.sut.acknowledgedAttempts.isEmpty }
        #expect(rig.sut.acknowledgedAttempts.isEmpty)
    }

    @Test func givenCheckDuringSending_whenCheckStores_thenSendingAttemptIsNotAcknowledged() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.setAttempts([attempt(executing: true)])
        await waitUntil { rig.sut.projection.stop != nil }
        // when
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.sut.acknowledgedAttempts.isEmpty)
    }

    @Test func givenNotSentLines_whenCheckAgainTapped_thenBothSourcesClear() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.prepareResult = { _ in .failed(.busy) }
        rig.sut.didTapStop()
        await waitUntil { rig.sut.detail?.notes.first == PendingLaunchDetailPresentation.notSentNote }
        rig.useCase.setAttempts([attempt(failure: .busy)])
        // when
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.activeOperations == 0 }
        // then
        #expect(rig.sut.detail?.notes.contains(PendingLaunchDetailPresentation.notSentNote) == false)
    }

    // MARK: - Survival

    @Test func givenRequestedAttempt_whenBackAndReselected_thenSameOutcomeCard() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.setAttempts([attempt(.accepted(StopFixture.receipt(basis: "observed_settlement")))])
        await waitUntil { rig.sut.detail?.kind == .stopRequested }
        // when
        rig.sut.didTapBack()
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .stopRequested }
        // then
        #expect(rig.sut.detail?.title == "Stop requested")
    }
}
