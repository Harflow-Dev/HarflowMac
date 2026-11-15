import Foundation
@testable import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import Testing

// MARK: - PendingLaunchesTopBarVMTests

/// What `PendingLaunchesVM` writes to the window's top bar through `PendingLaunchesTopBarRouting`.
@MainActor @Suite
struct PendingLaunchesTopBarVMTests {
    private let idA = "20261110-093000-a17c92"
    private let idB = "20261110-093200-b28d03"

    private struct Rig {
        let useCase: ScriptedUseCase
        let sut: PendingLaunchesVM
        let topBar: MockPendingLaunchesTopBarRouting
    }

    private func rig(recorded: Bool = false) -> Rig {
        let rows = [PendingLaunchesFixture.item(id: idA), PendingLaunchesFixture.item(id: idB, state: "claimed")]
        let useCase = ScriptedUseCase(snapshot: .init(inventory: .init(rows: rows, completedCheck: true)), lease: PendingLaunchReadLease())
        if recorded { useCase.lookupFor = { ScriptedUseCase.recorded($0) } }
        let routing = MockPendingLaunchesRouting()
        given(routing).openRecordedTask(.any).willReturn()
        let topBar = PendingLaunchesTopBarRoutingMock.make()
        let sut = PendingLaunchesVM(useCase: useCase, routing: routing, topBarRouting: topBar)
        return Rig(useCase: useCase, sut: sut, topBar: topBar)
    }

    private func appeared(_ rig: Rig) async {
        rig.sut.didAppear()
        await waitUntil { rig.sut.presentation.kind == .inventory }
    }

    private func drainMain() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    private func content(_ title: String) -> PageTopBarContent { .pendingLaunches(title: title) }

    private func published(_ rig: Rig, _ title: String, times: Int) {
        verify(rig.topBar).publishTopBar(.value(content(title)), tag: .value(rig.sut.topBarTag)).called(.exactly(times))
    }

    @Test func givenTheScreenAppears_whenSettled_thenItPublishesTheInventoryTitleWithThePendingLaunchBadgeOnceAndActivates() async {
        // given
        let rig = rig()
        // when
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        await drainMain()
        // then
        published(rig, "Pending launches", times: 1)
        verify(rig.topBar).activateTopBar(tag: .value(rig.sut.topBarTag)).called(1)
        #expect(rig.sut.topBarContent == .pendingLaunchesInventory)
        #expect(rig.sut.topBarContent.badge.label == "Pending launch")
    }

    @Test func givenAQualifiedLookup_whenARowIsSelected_thenTheBarShowsTheLaunchTitle() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        // when
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        await drainMain()
        // then
        published(rig, "Review launch admission checks", times: 1)
        #expect(rig.sut.topBarContent == content("Review launch admission checks"))
    }

    @Test func givenACheckInFlight_whenARowIsSelected_thenTheBarShowsThePendingLaunchTitleUntilTheLookupArrives() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.useCase.holdCalls = true
        // when
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.useCase.checks.count == 1 }
        await drainMain()
        // then: the placeholder, not the inventory title and not a launch title.
        #expect(rig.sut.detail?.kind == .checking)
        published(rig, "Pending launch", times: 1)
        published(rig, "Review launch admission checks", times: 0)
        // when
        rig.useCase.releaseHeld()
        await waitUntil { rig.sut.detail?.kind == .waiting }
        await drainMain()
        // then
        published(rig, "Review launch admission checks", times: 1)
    }

    @Test func givenARecordedLookup_whenARowIsSelected_thenTheBarShowsThePendingLaunchTitle() async {
        // given
        let rig = rig(recorded: true)
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        // when
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .recorded }
        await drainMain()
        // then
        #expect(rig.sut.topBarContent == content("Pending launch"))
        published(rig, "Review launch admission checks", times: 0)
    }

    @Test func givenAQualifiedTitle_whenBack_thenTheBarReturnsToTheInventoryTitle() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        // when
        rig.sut.didTapBack()
        await drainMain()
        // then: written again after having left it.
        published(rig, "Pending launches", times: 2)
        #expect(rig.sut.topBarContent == .pendingLaunchesInventory)
    }

    @Test func givenAPublishedTitle_whenALaterBuildKeepsTheSameTitle_thenNothingIsRepublished() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting && rig.sut.detail?.isActionEnabled == true }
        await drainMain()
        // when: Check again stores a fresh lookup and rebuilds the detail with the same title.
        rig.sut.didTapCheckAgain()
        await waitUntil { rig.useCase.checks.count == 2 }
        await drainMain()
        // then
        published(rig, "Review launch admission checks", times: 1)
        published(rig, "Pending launches", times: 1)
        published(rig, "Pending launch", times: 1)
    }

    @Test func givenASelection_whenTheOtherRowIsSelectedAfterBack_thenTheTitleFollowsTheNewLaunchWithoutStaleContent() async {
        // given
        let rig = rig()
        await appeared(rig)
        defer { rig.sut.didDisappear() }
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        rig.sut.didTapBack()
        // when
        rig.sut.didSelectRow(idB)
        await waitUntil { rig.sut.detail?.kind == .preparing }
        await drainMain()
        // then: the second row has the same fixture title, so the bar returns to it after the inventory.
        #expect(rig.sut.topBarContent == content("Review launch admission checks"))
        published(rig, "Review launch admission checks", times: 2)
    }

    @Test func givenAShownScreen_whenItDisappears_thenTheBarIsDeactivatedAndClearedOnce() async {
        // given
        let rig = rig()
        await appeared(rig)
        // when
        rig.sut.didDisappear()
        rig.sut.didDisappear()
        // then
        verify(rig.topBar).deactivateTopBar(tag: .value(rig.sut.topBarTag)).called(1)
        verify(rig.topBar).clearTopBar(tag: .value(rig.sut.topBarTag)).called(1)
        #expect(rig.sut.lastPublishedTopBar == nil)
    }

    @Test func givenASelectedLaunch_whenTheScreenDisappears_thenNothingIsPublishedAfterTheWithdrawal() async {
        // given
        let rig = rig()
        await appeared(rig)
        rig.sut.didSelectRow(idA)
        await waitUntil { rig.sut.detail?.kind == .waiting }
        await drainMain()
        // when
        rig.sut.didDisappear()
        await drainMain()
        // then: the selection reset on the way out did not write the inventory title back.
        published(rig, "Pending launches", times: 1)
        published(rig, "Review launch admission checks", times: 1)
        verify(rig.topBar).deactivateTopBar(tag: .value(rig.sut.topBarTag)).called(1)
    }

    @Test func givenAFirstAppearance_whenTheScreenReappears_thenTheInventoryTitleIsPublishedAgain() async {
        // given
        let rig = rig()
        await appeared(rig)
        rig.sut.didDisappear()
        // when
        rig.sut.didAppear()
        defer { rig.sut.didDisappear() }
        await drainMain()
        // then
        published(rig, "Pending launches", times: 2)
        verify(rig.topBar).activateTopBar(tag: .value(rig.sut.topBarTag)).called(2)
    }

    @Test func givenNoTopBarRouting_whenTheScreenRuns_thenNothingFailsAndNothingIsWritten() async {
        // given
        let rows = [PendingLaunchesFixture.item(id: idA)]
        let useCase = ScriptedUseCase(snapshot: .init(inventory: .init(rows: rows, completedCheck: true)), lease: PendingLaunchReadLease())
        let sut = PendingLaunchesVM(useCase: useCase)
        // when
        sut.didAppear()
        await waitUntil { sut.presentation.kind == .inventory }
        sut.didSelectRow(idA)
        await waitUntil { sut.detail?.kind == .waiting }
        sut.didDisappear()
        // then
        #expect(sut.lastPublishedTopBar == nil)
    }

    @Test func givenTheViewModel_whenAskingForItsTag_thenItIsTheVMIdentityForThePendingLaunchesSubject() {
        // given
        let rig = rig()
        // when / then
        #expect(rig.sut.topBarTag == TaskTopBarHolder.Tag(writer: ObjectIdentifier(rig.sut), subject: .pendingLaunches))
    }
}
