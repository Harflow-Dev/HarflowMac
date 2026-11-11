import Combine
import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
@testable import MonitorCore
import Testing

// MARK: - StopScriptedUseCase

@MainActor
final class StopScriptedUseCase: PendingLaunchesUseCase {
    let subject: CurrentValueSubject<PendingLaunchSnapshot, Never>
    let lease = PendingLaunchReadLease()
    var lookupFor: (PendingLaunchSelection) -> PendingLaunchLookup
    var prepareResult: ((PendingLaunchSelection) -> PendingLaunchStopPreparation)?
    var submitResult: PendingLaunchStopAdmission = .submitted(UUID())
    var holdPrepare = false
    var holdChecks = false
    private(set) var checks: [PendingLaunchSelection] = []
    private(set) var prepares: [PendingLaunchSelection] = []
    private(set) var submits: [PendingLaunchStopConfirmation] = []
    private(set) var confirmations: [PendingLaunchStopConfirmation] = []
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(rows: [String]) {
        var snapshot = PendingLaunchSnapshot(inventory: .init(rows: rows.map { PendingLaunchesFixture.item(id: $0) }, completedCheck: true))
        snapshot.currentRuntime = StopFixture.runtime
        self.subject = CurrentValueSubject(snapshot)
        self.lookupFor = { selection in
            PendingLaunchLookup(selection: selection, value: PendingLaunchesFixture.lookup(PendingLaunchesFixture.item(id: selection.taskID)),
                                failure: nil)
        }
    }

    var snapshot: PendingLaunchSnapshot { subject.value }
    func snapshotPublisher() -> AnyPublisher<PendingLaunchSnapshot, Never> { subject.eraseToAnyPublisher() }
    func acquireReadLease() -> PendingLaunchReadLease? { lease }
    func releaseReadLease(_: PendingLaunchReadLease) {}
    func refresh(lease _: PendingLaunchReadLease) async {}
    func bindSelection(taskID: String?, lease: PendingLaunchReadLease) -> PendingLaunchSelection? {
        taskID.map { PendingLaunchSelection(taskID: $0, lease: lease) }
    }

    func check(selection: PendingLaunchSelection) async -> PendingLaunchLookup {
        checks.append(selection)
        if holdChecks { await withCheckedContinuation { waiting.append($0) } }
        let lookup = lookupFor(selection)
        store(lookup)
        return lookup
    }

    func resolveRecorded(selection _: PendingLaunchSelection) async -> PendingLaunchRecordedResult { .failed(.unavailable) }

    func prepareStop(selection: PendingLaunchSelection) async -> PendingLaunchStopPreparation {
        prepares.append(selection)
        if holdPrepare { await withCheckedContinuation { waiting.append($0) } }
        if let prepareResult { return prepareResult(selection) }
        let confirmation = StopFixture.confirmation(taskID: selection.taskID)
        confirmations.append(confirmation)
        return .confirmation(confirmation)
    }

    func submitStop(confirmation: PendingLaunchStopConfirmation) -> PendingLaunchStopAdmission {
        submits.append(confirmation)
        return submitResult
    }

    func releaseHeld() {
        holdPrepare = false
        holdChecks = false
        let pending = waiting
        waiting = []
        pending.forEach { $0.resume() }
    }

    func setAttempts(_ attempts: [PendingLaunchStopAttempt]) {
        var next = subject.value
        next.attempts = attempts
        subject.send(next)
    }

    /// A real change that delivers a new snapshot without touching attempts or lookups.
    func touch() {
        var next = subject.value
        next.inventory.isStale.toggle()
        subject.send(next)
    }

    func changeRuntimeIdentity() {
        var next = subject.value
        next.runtimeIdentity = UUID()
        subject.send(next)
    }

    private func store(_ lookup: PendingLaunchLookup) {
        var next = subject.value
        next.lookups = next.lookups.filter { $0.selection.lease != lookup.selection.lease } + [lookup]
        subject.send(next)
    }
}

final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [PendingLaunchStopRequest] = []
    private var dismissals = 0
    var requests: [PendingLaunchStopRequest] { lock.withLock { stored } }
    var dismissCount: Int { lock.withLock { dismissals } }
    func add(_ request: PendingLaunchStopRequest) { lock.withLock { stored.append(request) } }
    func dismissed() { lock.withLock { dismissals += 1 } }
}

// MARK: - PendingLaunchesStopVMTests

@MainActor @Suite
struct PendingLaunchesStopVMTests {
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

    private func presented(_ rig: Rig) async -> PendingLaunchStopRequest? {
        rig.sut.didTapStop()
        await waitUntil { !rig.box.requests.isEmpty }
        return rig.box.requests.last
    }

    private func attempt(_ outcome: TaskPendingLaunchStopOutcome? = nil, failure: PendingLaunchFailure? = nil,
                         executing: Bool = false, taskID: String? = nil) -> PendingLaunchStopAttempt {
        StopFixture.attempt(executing: executing, failure: failure, outcome: outcome, taskID: taskID ?? idA)
    }

    // MARK: - Tap

    @Test func givenCheckInFlight_whenStopTapped_thenInertAndNothingQueued() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.holdChecks = true
        rig.sut.didTapDetailCheckAgain()
        await waitUntil { rig.sut.detail?.stop == .disabled }
        // when
        rig.sut.didTapStop()
        // then
        #expect(rig.useCase.prepares.isEmpty)
        #expect(rig.sut.activeOperations == 1)
        rig.useCase.releaseHeld()
        await waitUntil { rig.sut.detail?.stop == .enabled }
        #expect(rig.useCase.prepares.isEmpty)
    }

    @Test func givenIdle_whenStopTapped_thenPreparesOnceAndPresentsTheCapturedID() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        // when
        let request = try #require(await presented(rig))
        // then
        #expect(rig.useCase.prepares.count == 1)
        #expect(rig.box.requests.count == 1)
        #expect(request.taskID == idA)
        #expect(request.id == rig.useCase.confirmations.first?.id)
    }

    @Test func givenPreparationHeldOpen_whenTapped_thenStopIsDisabledMeanwhile() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.holdPrepare = true
        // when
        rig.sut.didTapStop()
        await waitUntil { rig.useCase.prepares.count == 1 }
        await waitUntil { rig.sut.detail?.stop == .disabled }
        rig.sut.didTapStop()
        // then
        #expect(rig.useCase.prepares.count == 1)
        rig.useCase.releaseHeld()
        await waitUntil { !rig.box.requests.isEmpty }
    }

    // MARK: - Confirmation

    @Test func givenGenerationMismatch_whenPrepared_thenNoSheet() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.prepareResult = { .confirmation(StopFixture.confirmation(taskID: $0.taskID, generation: StopFixture.otherGeneration)) }
        // when
        rig.sut.didTapStop()
        await waitUntil { rig.useCase.prepares.count == 1 && rig.sut.activeOperations == 0 }
        // then
        #expect(rig.box.requests.isEmpty)
        #expect(rig.sut.stopConfirmation == nil)
        #expect(rig.sut.detail?.notes.contains(PendingLaunchDetailPresentation.notSentNote) == false)
    }

    @Test func givenIneligibleReprojectedLookup_whenPrepared_thenNoSheet() async {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.prepareResult = { selection in
            // The preparation's own read stored a lookup that no longer offers Stop.
            let item = PendingLaunchesFixture.item(id: selection.taskID, cancelSupport: "unsupported")
            var next = rig.useCase.subject.value
            next.lookups = [PendingLaunchLookup(selection: selection, value: PendingLaunchesFixture.lookup(item), failure: nil)]
            rig.useCase.subject.send(next)
            return .confirmation(StopFixture.confirmation(taskID: selection.taskID))
        }
        // when
        rig.sut.didTapStop()
        await waitUntil { rig.useCase.prepares.count == 1 && rig.sut.activeOperations == 0 }
        // then
        #expect(rig.box.requests.isEmpty)
    }

    @Test func givenSheet_whenConfirmed_thenSubmitsOnceAndTitleFocusFollowsDismissal() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let request = try #require(await presented(rig))
        let before = rig.sut.titleFocusRequest
        // when
        request.confirm()
        request.confirm()
        #expect(rig.sut.titleFocusRequest == before)
        request.didDismiss(request.id)
        // then
        #expect(rig.useCase.submits.count == 1)
        #expect(rig.useCase.submits.first?.id == request.id)
        #expect(rig.sut.titleFocusRequest == before + 1)
        #expect(rig.sut.stopFocusRequest == 0)
    }

    @Test func givenSheet_whenUserCancels_thenNoSubmitAndStopFocusAfterDismissal() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let request = try #require(await presented(rig))
        // when
        request.cancel(.userCancel)
        #expect(rig.sut.stopFocusRequest == 0)
        request.didDismiss(request.id)
        // then
        #expect(rig.useCase.submits.isEmpty)
        #expect(rig.sut.stopFocusRequest == 1)
        #expect(rig.sut.stopConfirmation == nil)
    }

    @Test func givenSheet_whenDiscarded_thenNoSubmitAndNoFocusToken() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let request = try #require(await presented(rig))
        // when
        request.cancel(.discard)
        request.didDismiss(request.id)
        // then
        #expect(rig.useCase.submits.isEmpty)
        #expect(rig.sut.stopFocusRequest == 0 && rig.sut.titleFocusRequest == 0)
    }

    private enum Exit: CaseIterable { case back, disappear, runtimeChange, reselect }

    @Test func givenSheet_whenScreenMovesOn_thenDismissedOnceAndLateConfirmIsInert() async throws {
        for exit in Exit.allCases {
            // given
            let rig = rig()
            await ready(rig)
            let request = try #require(await presented(rig))
            // when
            switch exit {
            case .back: rig.sut.didTapBack()
            case .disappear: rig.sut.didDisappear()
            case .runtimeChange:
                rig.useCase.changeRuntimeIdentity()
                await waitUntil { rig.sut.detail == nil }
            case .reselect:
                rig.sut.didTapBack()
                rig.sut.didSelectRow(idA)
            }
            request.confirm()
            request.cancel(.userCancel)
            // then
            #expect(rig.box.dismissCount == 1, "\(exit)")
            #expect(rig.useCase.submits.isEmpty, "\(exit)")
            #expect(rig.sut.stopConfirmation == nil)
            rig.sut.didDisappear()
        }
    }

    @Test func givenStaleCallbackForEarlierSheet_whenNewerSheetOpen_thenNewerIsUntouched() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let first = try #require(await presented(rig))
        first.cancel(.userCancel)
        await waitUntil { rig.sut.detail?.stop == .enabled }
        rig.sut.didTapStop()
        await waitUntil { rig.box.requests.count == 2 }
        let second = rig.box.requests[1]
        // when
        first.cancel(.userCancel)
        first.confirm()
        // then
        #expect(rig.sut.stopConfirmation?.confirmation.id == second.id)
        #expect(rig.useCase.submits.isEmpty)
        #expect(rig.useCase.prepares.count == 2)
    }

    @Test func givenStaleConfirmationLeftBehind_whenStopTappedAgain_thenReplacedNotBlocking() async throws {
        // given: the sheet's callbacks were lost, leaving the confirmation held.
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        _ = try #require(await presented(rig))
        #expect(rig.sut.stopConfirmation != nil)
        // when
        rig.sut.didTapStop()
        await waitUntil { rig.box.requests.count == 2 }
        // then
        #expect(rig.useCase.prepares.count == 2)
        #expect(rig.sut.stopConfirmation?.confirmation.id == rig.box.requests[1].id)
    }

    @Test func givenDismissalOfAnotherConfirmation_whenItArrives_thenNoFocusTokenMoves() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        let request = try #require(await presented(rig))
        request.cancel(.userCancel)
        // when: a dismissal for some other confirmation
        request.didDismiss(UUID())
        // then
        #expect(rig.sut.stopFocusRequest == 0)
        request.didDismiss(request.id)
        #expect(rig.sut.stopFocusRequest == 1)
    }

    @Test func givenClearedNotSentLine_whenStaleConfirmationIsReplaced_thenItStaysCleared() async throws {
        // given
        let rig = rig()
        await ready(rig)
        defer { rig.sut.didDisappear() }
        _ = try #require(await presented(rig))
        rig.sut.notSentCleared = true
        // when
        rig.sut.didTapStop()
        await until("second sheet") { rig.box.requests.count == 2 }
        // then
        #expect(rig.sut.notSentCleared)
    }

    // MARK: - Preparation results

    @Test func givenPreparationResult_whenItArrives_thenOnlyLocalRefusalsShowNotSent() async {
        let cases: [(PendingLaunchFailure, Bool)] = [
            (.changed, false), (.recorded, false), (.unsupported, false), (.superseded, false),
            (.busy, true), (.capacity, true), (.tool(.refused(code: "x", message: "y")), true)
        ]
        for (failure, notSent) in cases {
            // given
            let rig = rig()
            await ready(rig)
            rig.useCase.prepareResult = { _ in .failed(failure) }
            // when
            rig.sut.didTapStop()
            await waitUntil { rig.useCase.prepares.count == 1 && rig.sut.activeOperations == 0 }
            // then
            #expect(rig.box.requests.isEmpty, "\(failure)")
            #expect(rig.sut.stopPrepareNotSent == notSent, "\(failure)")
            rig.sut.didDisappear()
        }
    }

    @Test func givenPreparationHeldOpen_whenScreenMovesOn_thenResultIsInert() async {
        for exit in Exit.allCases {
            // given
            let rig = rig()
            await ready(rig)
            rig.useCase.holdPrepare = true
            rig.sut.didTapStop()
            await waitUntil { rig.useCase.prepares.count == 1 }
            // when
            switch exit {
            case .back: rig.sut.didTapBack()
            case .disappear: rig.sut.didDisappear()
            case .runtimeChange:
                rig.useCase.changeRuntimeIdentity()
                await waitUntil { rig.sut.detail == nil }
            case .reselect:
                rig.sut.didTapBack()
                rig.sut.didSelectRow(idA)
            }
            let pending = rig.sut.lastOperation
            rig.useCase.releaseHeld()
            await pending?.value
            // then
            #expect(rig.box.requests.isEmpty, "\(exit)")
            #expect(!rig.sut.stopPrepareNotSent, "\(exit)")
            rig.sut.didDisappear()
        }
    }

    @Test func givenSubmitRefusals_whenConfirmed_thenChangedChecksOnceAndOthersShowNotSent() async throws {
        // given: changed
        let changed = rig()
        await ready(changed)
        changed.useCase.submitResult = .refused(.changed)
        let request = try #require(await presented(changed))
        let checks = changed.useCase.checks.count
        // when
        request.confirm()
        await waitUntil { changed.useCase.checks.count == checks + 1 }
        // then
        #expect(changed.useCase.submits.count == 1)
        #expect(!changed.sut.stopPrepareNotSent)
        changed.sut.didDisappear()
        // given: capacity
        let capacity = rig()
        await ready(capacity)
        capacity.useCase.submitResult = .refused(.capacity)
        let second = try #require(await presented(capacity))
        // when
        second.confirm()
        second.didDismiss(second.id)
        // then: Stop is shown again, so it takes focus after the sheet is gone.
        #expect(capacity.sut.stopPrepareNotSent)
        #expect(capacity.useCase.checks.count == 1)
        #expect(capacity.sut.stopFocusRequest == 1)
        capacity.sut.didDisappear()
    }

    // MARK: - No retry

    @Test func givenResolvedOrUnsafeAttempts_whenTimePasses_thenNoFurtherPrepareOrSubmit() async {
        let engine = ConversationDeliveryEngineError(code: "x", message: "m", data: nil)
        let outcomes: [TaskPendingLaunchStopOutcome?] = [
            .notDispatched(StopFixture.request, cause: .missingCapability("c")),
            .uncertain(StopFixture.request, cause: .receiptIdentityMismatch),
            .engineError(StopFixture.request, engine)
        ]
        for outcome in outcomes {
            // given
            let rig = rig()
            await ready(rig)
            // when
            rig.useCase.setAttempts([attempt(outcome)])
            await waitUntil { rig.sut.projection.stop != nil }
            rig.sut.didTapDetailCheckAgain()
            await waitUntil { rig.sut.activeOperations == 0 }
            // then
            #expect(rig.useCase.prepares.isEmpty)
            #expect(rig.useCase.submits.isEmpty)
            rig.sut.didDisappear()
        }
    }

}
