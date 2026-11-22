import Foundation
@testable import MainWindowFeature
import Testing

// MARK: - ParallelViewportClaimsTests

/// The viewport ownership model: the newest live view that has measured a width wins.
@Suite struct ParallelViewportClaimsTests {
    @Test func givenOlderMeasuredView_whenNewerViewClaimsAndOlderReportsAgain_thenOlderWidthApplies() {
        // given: B is unmeasured, so it does not outrank A's measurement.
        var claims = ParallelViewportClaims()
        let (viewA, viewB) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.claim(viewB)

        // when
        claims.report(viewA, offset: 0, width: 470)

        // then
        #expect(claims.effectiveWidth == 470)
        #expect(claims.owner == viewA)
    }

    @Test func givenNewerMeasuredView_whenOlderReports_thenNewerWidthStays() {
        // given
        var claims = ParallelViewportClaims()
        let (viewA, viewB) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.report(viewB, offset: 0, width: 480)

        // when
        claims.report(viewA, offset: 0, width: 300)

        // then
        #expect(claims.effectiveWidth == 480)
        #expect(claims.owner == viewB)
    }

    @Test func givenReportBeforeClaim_whenClaimedAndOlderReleases_thenWidthStays() {
        // given
        var claims = ParallelViewportClaims()
        let (viewA, viewB) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.report(viewB, offset: 0, width: 460)

        // when: the claim on a live token does nothing, then the older view goes away
        claims.claim(viewB)
        claims.release(viewA)

        // then
        #expect(claims.effectiveWidth == 460)
        #expect(claims.owner == viewB)
    }

    @Test func givenUnmeasuredSuccessor_whenMeasuredViewReleases_thenWidthIsHeldUntilSuccessorMeasures() {
        // given
        var claims = ParallelViewportClaims()
        let (viewA, viewB) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.claim(viewB)

        // when
        claims.release(viewA)

        // then
        #expect(claims.effectiveWidth == 460)
        #expect(claims.owner == nil)
        claims.report(viewB, offset: 0, width: 480)
        #expect(claims.effectiveWidth == 480)
    }

    @Test func givenLastLiveView_whenReleased_thenWidthIsZero() {
        // given
        var claims = ParallelViewportClaims()
        let viewA = UUID()
        claims.report(viewA, offset: 12, width: 460)

        // when
        claims.release(viewA)

        // then
        #expect(claims.effectiveWidth == 0 && claims.effectiveOffset == 0)
        #expect(claims.owner == nil)
    }

    @Test func givenReleasedView_whenItReportsAgain_thenReportIsIgnored() {
        // given
        var claims = ParallelViewportClaims()
        let (viewA, viewB) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.release(viewA)
        claims.report(viewB, offset: 0, width: 460)

        // when
        let accepted = claims.report(viewA, offset: 0, width: 300)

        // then
        #expect(!accepted)
        #expect(claims.effectiveWidth == 460)
        #expect(claims.owner == viewB)
    }

    @Test func givenReleasedView_whenItClaimsAgain_thenItIsRevivedWithItsLastGeometry() {
        // given
        var claims = ParallelViewportClaims()
        let viewA = UUID()
        claims.report(viewA, offset: 8, width: 460)
        claims.release(viewA)

        // when
        claims.claim(viewA)

        // then
        #expect(claims.effectiveWidth == 460 && claims.effectiveOffset == 8)
        #expect(claims.owner == viewA)
        let revivedReport = claims.report(viewA, offset: 0, width: 500)
        #expect(revivedReport)
        #expect(claims.effectiveWidth == 500)
    }

    @Test func givenReset_whenReleasedViewReportsLate_thenReportIsIgnoredAndNewClaimDoesNotReapplyAStaleWidth() {
        // given
        var claims = ParallelViewportClaims()
        let (viewA, viewC) = (UUID(), UUID())
        claims.report(viewA, offset: 0, width: 460)
        claims.release(viewA)
        claims.report(viewC, offset: 0, width: 300)

        // when
        claims.reset()

        // then
        #expect(claims.effectiveWidth == 0 && claims.effectiveOffset == 0)
        let lateReport = claims.report(viewA, offset: 0, width: 460)
        #expect(!lateReport)
        claims.claim(UUID())
        #expect(claims.effectiveWidth == 0)
        #expect(claims.hasEnded(viewA))
    }

    @Test func givenUnregisteredView_whenReleased_thenItIsRememberedAsEnded() {
        // given
        var claims = ParallelViewportClaims()
        let ghost = UUID()

        // when
        claims.release(ghost)

        // then
        #expect(claims.hasEnded(ghost))
        let ghostReport = claims.report(ghost, offset: 0, width: 460)
        #expect(!ghostReport)
    }

    @Test func givenMoreReleasedViewsThanTheCap_whenOldestIsChecked_thenOnlyTheMostRecentAreRemembered() {
        // given
        var claims = ParallelViewportClaims()
        let tokens = (0 ..< ParallelViewportClaims.endedCapacity + 1).map { _ in UUID() }

        // when
        for token in tokens { claims.release(token) }

        // then
        #expect(!claims.hasEnded(tokens[0]))
        #expect(tokens.dropFirst().allSatisfy { claims.hasEnded($0) })
    }
}
