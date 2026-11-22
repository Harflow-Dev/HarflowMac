import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

extension ParallelVMTests {
    /// A workflow activity with one selected conversation, subscribed and settled with no viewport width yet.
    private func ownedActivity() async -> (SUT, ParallelVM) {
        let harness = makeSUT()
        let sut = harness.sut.makeWorkflowActivity()
        let first = task(id: "first")
        harness.tasksBox.value = ["first": first]
        sut.didAppear()
        harness.tasksSubject.send([first])
        await waitUntil { sut.columns.count == 1 && sut.isPresentationSettled }
        sut.selectConversation("first")
        return (harness, sut)
    }

    @Test func givenReplacedViewAtUnchangedWidth_whenOldOwnerReleases_thenViewportAndLeaseAreKept() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when — the replacement reports the same width, which the unchanged-value guard ignores, then the old view disappears.
        sut.updateViewport(owner: ownerB, offset: 0, width: 460)
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
        #expect(sut.residentColumnCount == 1)
    }

    @Test func givenOldOwnerReleasedFirst_whenReplacementClaimsAtSameWidth_thenMemberIsLeasedAgain() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.leasedMemberCount == 0 && sut.isPresentationSettled }

        // when
        sut.updateViewport(owner: ownerB, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
    }

    @Test func givenCurrentOwnerWithNoSuccessor_whenItReleases_thenViewportZeroesAndLeasesAreReleased() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let owner = UUID()
        sut.updateViewport(owner: owner, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when
        sut.releaseViewport(owner: owner)

        // then
        #expect(sut.leasedMemberCount == 0)
    }

    @Test func givenOwnerHoldingViewport_whenActivityIsSuspended_thenOwnerIsClearedAndLaterClaimRestoresResidency() async {
        // given
        let (harness, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerC = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when
        sut.suspendWorkflowActivity()

        // then — suspension zeroed the viewport and released the leases regardless of the owner.
        #expect(sut.leasedMemberCount == 0)
        #expect(sut.viewportOwner == nil)
        #expect(sut.viewportClaims.effectiveWidth == 0)

        // when — the stale owner's release is a no-op, and a new owner's claim restores residency.
        sut.releaseViewport(owner: ownerA)
        #expect(sut.leasedMemberCount == 0)
        sut.didAppear()
        harness.tasksSubject.send([task(id: "first")])
        sut.updateViewport(owner: ownerC, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
    }

    @Test func givenNewerOwner_whenOlderOwnerReportsAnotherWidthAndReleases_thenViewportLeaseAndOwnerAreKept() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        sut.updateViewport(owner: ownerB, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when — the replaced view's late geometry and disappearance arrive.
        sut.updateViewport(owner: ownerA, offset: 0, width: 300)
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.isPresentationSettled }

        // then
        #expect(sut.viewportOwner == ownerB)
        #expect(sut.leasedMemberCount == 1)
        #expect(sut.residentColumnCount == 1)
    }

    @Test func givenOwnerHoldingViewport_whenActivityDisappears_thenOwnerIsCleared() async {
        // given
        let (_, sut) = await ownedActivity()
        sut.updateViewport(owner: UUID(), offset: 0, width: 460)

        // when
        sut.didDisappear()

        // then
        #expect(sut.viewportOwner == nil)
    }

    // MARK: - Newest live measured view wins

    @Test func givenMeasuredOwner_whenClaimOnlyViewClaimsAndReleases_thenViewportAndLeaseAreKept() async {
        // given: a view that appears (claims, no width) and goes away must not zero the live view's viewport.
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when
        sut.claimViewport(owner: ownerB)
        sut.releaseViewport(owner: ownerB)
        await waitUntil { sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
        #expect(sut.residentColumnCount == 1)
    }

    @Test func givenReleasedOwnerAndSuccessor_whenZombieReportsAndSuccessorReleases_thenViewportZeroesAndReleasedViewStaysIgnored() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.leasedMemberCount == 0 && sut.isPresentationSettled }
        sut.updateViewport(owner: ownerB, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when — the released view reports again (ignored), the successor re-measures, then goes away.
        sut.updateViewport(owner: ownerA, offset: 0, width: 300)
        #expect(sut.viewportOwner == ownerB)
        #expect(sut.viewportClaims.effectiveWidth == 460)
        sut.updateViewport(owner: ownerB, offset: 0, width: 480)
        #expect(sut.viewportClaims.effectiveWidth == 480)
        sut.releaseViewport(owner: ownerB)
        await waitUntil { sut.leasedMemberCount == 0 && sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 0)
    }

    @Test func givenReleasedOwner_whenSuspendedAndItReportsLate_thenReportIsIgnored() async {
        // given
        let (harness, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }
        sut.releaseViewport(owner: ownerA)
        sut.suspendWorkflowActivity()
        sut.didAppear()
        harness.tasksSubject.send([task(id: "first")])
        await waitUntil { sut.isPresentationSettled }

        // when
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 0)
    }

    @Test func givenReleasedOwner_whenItClaimsAgain_thenItsLastWidthIsRestoredAndMemberIsLeased() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.leasedMemberCount == 0 && sut.isPresentationSettled }

        // when
        sut.claimViewport(owner: ownerA)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
    }

    @Test func givenUnmeasuredSuccessor_whenMeasuredOwnerReleases_thenLeaseIsHeldUntilSuccessorMeasures() async {
        // given
        let (_, sut) = await ownedActivity()
        defer { sut.didDisappear() }
        let ownerA = UUID()
        let ownerB = UUID()
        sut.updateViewport(owner: ownerA, offset: 0, width: 460)
        await waitUntil { sut.leasedMemberCount == 1 && sut.isPresentationSettled }

        // when
        sut.claimViewport(owner: ownerB)
        sut.releaseViewport(owner: ownerA)
        await waitUntil { sut.isPresentationSettled }

        // then
        #expect(sut.leasedMemberCount == 1)
        sut.updateViewport(owner: ownerB, offset: 0, width: 480)
        await waitUntil { sut.isPresentationSettled }
        #expect(sut.leasedMemberCount == 1)
    }
}
