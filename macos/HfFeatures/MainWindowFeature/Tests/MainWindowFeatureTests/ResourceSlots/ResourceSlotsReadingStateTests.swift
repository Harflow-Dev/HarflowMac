import Foundation
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor
struct ResourceSlotsReadingStateTests {
    @Test func givenVerifiedDeparture_whenOutgoingZeroAndTransientShortExtentArrive_thenTypedTargetsRecoverTheOriginalAnchor() throws {
        let state = savedState()
        let savedAnchor = state.retainedAnchor
        state.prepareDeparture(ownerRowID: "shared")
        state.update(geometry(0, contentHeight: 500), ready: true)
        #expect(state.retainedOffset == 2500 && state.retainedAnchor == savedAnchor)
        state.endAppearance()
        beginReturn(state)
        state.update(geometry(0, contentHeight: 500), ready: true)
        #expect(state.retainedOffset == 2500 && state.isRestoring)

        let commands = try materializeOwner(state)
        #expect(commands.map(\.target) == [.group("shared"), .owner("shared")])
        #expect(Set(commands.map(\.target)).count == 2, "Equal literal group and owner IDs must remain separate commands")
        #expect(!state.consumeIDScrollRequest(commands[0]) && !state.consumeIDScrollRequest(commands[1]))
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.position.y == 2500 && state.pointRequestCount == 1)
        try finishExact(state)
        #expect(state.restorationOutcome == .exact)
        #expect(state.retainedOffset == 2500 && state.retainedAnchor == savedAnchor)
        #expect(state.focusRestorationPending, "A scroll result does not acknowledge native focus")
        let focusRequest = try #require(state.focusReturnRequest)
        state.acknowledgeFocusReturn(token: focusRequest.token)
        #expect(!state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
        #expect(state.focusReturnRequest == nil && state.focusedRowID == "shared")
    }

    @Test(arguments: [true, false])
    func givenMatchingPairAndScrollArriveInEitherOrder_whenPresentedWithoutAnotherPairCallback_thenThePairCanQualify(_ pairFirst: Bool) throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        let pair = frames(contentY: 2597, offset: 2500)
        if pairFirst {
            state.updateOwner(rowID: "shared", groupID: "shared", frames: pair)
            #expect(state.visibleOwnerFrame(rowID: "shared") == nil)
            state.update(geometry(2500), ready: true)
        } else {
            state.update(geometry(2500), ready: true)
            #expect(state.visibleOwnerFrame(rowID: "shared") == nil)
            state.updateOwner(rowID: "shared", groupID: "shared", frames: pair)
        }
        for _ in 0 ..< 4 {
            state.presentedFrame()
        }
        #expect(state.restorationOutcome == .exact)
        #expect(state.retainedOffset == 2500)
        #expect(state.visibleOwnerFrame(rowID: "shared")?.frame.minY == 97)
    }

    @Test func givenContent97ViewportMinus2452AndScroll2500_whenPresented_thenTheIncoherentPairCannotIssueAPointRequest() throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        state.update(geometry(2500), ready: true)
        state.updateOwner(rowID: "shared", groupID: "shared", frames: .init(
            viewport: CGRect(x: 0, y: -2452, width: 120, height: 64),
            content: CGRect(x: 0, y: 97, width: 120, height: 64)
        ))
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.visibleOwnerFrame(rowID: "shared") == nil)
        #expect(state.pointRequestCount == 0 && state.restorationOutcome == nil && state.isRestoring)
        #expect(state.retainedOffset == 2500)
        state.updateOwner(rowID: "shared", groupID: "shared", frames: frames(contentY: 2597, offset: 2500))
        for _ in 0 ..< 4 {
            state.presentedFrame()
        }
        #expect(state.restorationOutcome == .exact, "An earlier mismatched callback must not poison a later coherent pair")
    }

    @Test func givenViewportFrameStaysZero_whenContentAndScrollMoveTogether_thenNoCachedOffsetStampSurvives() throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        state.updateOwner(rowID: "shared", groupID: "shared", frames: frames(contentY: 2646, offset: 2646))
        #expect(state.visibleOwnerFrame(rowID: "shared") == nil)
        state.update(geometry(2646), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.position.y == 2549, "Fresh content origin minus the saved97-point viewport position determines refinement")
        updateOwner(state, offset: 2549, contentY: 2646)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.restorationOutcome == .exact)
        #expect(state.retainedAnchor?.relativeY == 97 && state.retainedOffset == 2549)
    }

    @Test func givenFirstPointWasRequested_whenCoherentContentOriginChanges_thenOneBoundedAdaptiveCorrectionUsesTheNewOrigin() throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.position.y == 2500 && state.pointRequestCount == 1)
        updateOwner(state, offset: 2597, contentY: 2646)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.position.y == 2549 && state.pointRequestCount == 2)
        #expect(state.isRestoring, "Issuing an adaptive point does not establish that native geometry reached it")
        updateOwner(state, offset: 2549, contentY: 2646)
        state.presentedFrame()
        #expect(state.isRestoring, "One coherent presented sample is insufficient")
        state.presentedFrame()
        #expect(state.restorationOutcome == .exact && state.retainedAnchor?.relativeY == 97)
    }

    @Test func givenNearEndOwnerCannotReachItsOldViewportPoint_whenTheIssuedPointIsClamped_thenBoundaryAlignmentIsNotExactReturn() throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        updateOwner(state, offset: 2200, contentY: 2490, contentHeight: 2600)
        for _ in 0 ..< 4 {
            state.presentedFrame()
        }
        #expect(state.position.y == 2200)
        #expect(state.restorationOutcome == .boundaryAligned && state.restorationOutcome != .exact)
        #expect(state.retainedOffset == 2200)
        let visible = try #require(state.visibleOwnerFrame(rowID: "shared"))
        #expect(visible.frame.minY == 290, "The visible position must reflect the physical boundary clamp")
        #expect(state.canRestoreFocus(rowID: "shared", frame: visible.frame, geometryOffset: visible.offset))
    }

    @Test func givenContinuallyChangingCoherentTargets_whenPointRequestBudgetEnds_thenFallbackIsTerminalAndDiscardsTheOldAnchor() throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        for attempt in 0 ... ResourceSlotsReadingState.maximumPointRequests {
            updateOwner(state, offset: 2000, contentY: 2100 + CGFloat(attempt) * 10)
            state.presentedFrame()
            state.presentedFrame()
        }
        #expect(ResourceSlotsReadingState.maximumPointRequests <= 8 && ResourceSlotsReadingState.maximumRestorationFrames <= 64)
        #expect(state.pointRequestCount == ResourceSlotsReadingState.maximumPointRequests)
        #expect(state.restorationFrames <= ResourceSlotsReadingState.maximumRestorationFrames)
        #expect(state.restorationOutcome == .fallback && !state.isRestoring)
        #expect(state.focusedRowID == nil && !state.focusRestorationPending)
        #expect(state.retainedAnchor?.relativeY != 97, "The failed desired anchor must not survive as the current reading snapshot")
        if let replacement = state.retainedAnchor {
            let current = try #require(state.visibleOwnerFrame(rowID: "shared"))
            #expect(replacement.rowID == "shared" && replacement.relativeY == current.frame.minY)
        }
        #expect(state.retainedOffset == 2000, "Fallback adopts the actually observed valid point, not the unreached request")
    }

    @Test(arguments: ["noGeometry", "missingGroup", "missingOwner", "movingIncoherent"])
    func givenTargetsNeverQualify_whenMountedReadyFramesReachTheirBound_thenLoadingDoesNotSpendTheBudgetAndFallbackEndsIt(_ missing: String) {
        let state = savedState()
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        beginReturn(state, ready: false)
        for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            state.presentedFrame()
        }
        #expect(state.isRestoring && state.restorationFrames == 0)
        state.setReady(true)
        var lastOffset: CGFloat?
        for frame in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            if missing == "noGeometry" {
                state.update(.init(offset: 0, contentHeight: 0, viewportHeight: 0), ready: true)
            } else {
                let offset: CGFloat = missing == "missingOwner" ? 97 : 30 + CGFloat(frame)
                state.update(geometry(offset), ready: true)
                lastOffset = offset
                if missing == "missingOwner" {
                    state.updateGroup(groupID: "shared", frames: frames(contentY: 97, offset: 97, height: 7000))
                } else if missing == "movingIncoherent" {
                    state.updateGroup(groupID: "shared", frames: frames(contentY: 97, offset: offset + 49, height: 7000))
                }
            }
            state.presentedFrame()
            if let request = state.idScrollRequest { #expect(state.consumeIDScrollRequest(request)) }
        }
        #expect(state.restorationOutcome == .fallback && !state.isRestoring)
        #expect(state.pointRequestCount <= ResourceSlotsReadingState.maximumPointRequests)
        #expect(state.retainedOffset == (lastOffset ?? 2500))
        #expect(state.retainedAnchor == nil && !state.hasAuthorizedFocusReturn)
        state.endAppearance()
        let retained = state.retainedOffset
        state.update(geometry(0), ready: true)
        state.presentedFrame()
        #expect(state.retainedOffset == retained)
    }

    @Test(arguments: ["collapsed", "removedOwner", "removedGroup"])
    func givenReturnedPresentationNoLongerHasExpandedOwner_whenReconciled_thenHeaderOrSafeFallbackDropsOwnerFocus(_ change: String) {
        let state = savedState()
        departAndReturn(state)
        let groups = change == "removedGroup" ? [] : [group(includeOwner: change != "removedOwner")]
        state.reconcile(groups: groups, expandedResourceIDs: change == "collapsed" ? [] : ["shared"])
        state.update(geometry(97, contentHeight: 800), ready: true)
        state.updateGroup(groupID: "shared", frames: frames(contentY: 97, offset: 97, height: 100))
        for _ in 0 ..< 10 {
            state.presentedFrame()
            if let request = state.idScrollRequest { #expect(state.consumeIDScrollRequest(request)) }
        }
        #expect(!state.isRestoring && !state.focusRestorationPending && state.focusedRowID == nil)
        #expect(state.retainedAnchor?.rowID == nil)
        #expect(state.restorationOutcome == (change == "removedGroup" ? .fallback : .boundaryAligned))
        #expect(state.retainedOffset == 97)
    }

    @Test(arguments: ["user", "focusOverride", "unmount", "runtime"])
    func givenDelayedIDCommand_whenItsLifecycleIsInvalidated_thenItCannotExecuteAfterward(_ invalidation: String) throws {
        let state = savedState()
        departAndReturn(state)
        state.update(geometry(0, contentHeight: 500), ready: true)
        state.presentedFrame()
        let obsolete = try #require(state.idScrollRequest)
        if invalidation == "user" || invalidation == "focusOverride" {
            state.update(geometry(275), ready: true)
            if invalidation == "focusOverride" {
                // Only a current-generation gain from a different row counts as user movement.
                _ = try #require(state.focusReturnRequest)
                state.observeFocusGain(rowID: "different", generation: state.focusObservationGeneration, token: nil)
            } else {
                state.cancelRestorationForUser()
            }
            #expect(state.restorationOutcome == .userCancelled && state.retainedOffset == 275)
        } else if invalidation == "unmount" {
            state.endAppearance()
        } else {
            state.resetForRuntime()
            #expect(state.retainedOffset == 0 && state.retainedAnchor == nil && state.focusedRowID == nil)
        }
        #expect(!state.consumeIDScrollRequest(obsolete))
        #expect(state.idScrollRequest == nil && !state.isRestoring)
        let count = state.pointRequestCount
        for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            state.presentedFrame()
        }
        #expect(state.pointRequestCount == count && !state.focusRestorationPending)
    }

    @Test func givenRawNonzeroInsets_whenRestoringTopAndShrunkBottom_thenBoundsAreRawAndBoundaryOutcomeStaysDistinct() throws {
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.update(geometry(-40, topInset: 24, bottomInset: 40), ready: true)
        #expect(state.retainedOffset == -24)
        state.prepareDeparture(ownerRowID: "owner")
        state.endAppearance()
        state.setSelected(true)
        state.authorizeFocusReturn()
        state.beginAppearance()
        state.update(geometry(0, topInset: 24, bottomInset: 40), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.position.y == -24)
        state.update(geometry(-24, topInset: 24, bottomInset: 40), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.restorationOutcome == .exact)
        let visible = CGRect(x: 0, y: 10, width: 100, height: 30)
        #expect(!state.canRestoreFocus(rowID: "owner", frame: visible, geometryOffset: 0))
        #expect(state.canRestoreFocus(rowID: "owner", frame: visible, geometryOffset: -24))
        let insetsFocusRequest = try #require(state.focusReturnRequest)
        state.acknowledgeFocusReturn(token: insetsFocusRequest.token)
        state.update(geometry(1500, topInset: 24, bottomInset: 40), ready: true)
        state.prepareDeparture(ownerRowID: "owner")
        state.endAppearance()
        state.setSelected(true)
        state.authorizeFocusReturn()
        state.beginAppearance()
        state.update(geometry(640, contentHeight: 1000, topInset: 24, bottomInset: 40), ready: true)
        for _ in 0 ..< 4 {
            state.presentedFrame()
        }
        #expect(state.restorationOutcome == .boundaryAligned && state.retainedOffset == 640)
    }

    @Test(arguments: ["shared", "different", "none"])
    func givenQualifiedScrollSuccess_whenFocusIsConfirmedOverriddenOrLost_thenOnlyTokenVerifiedCompletionIsConsumed(_ focus: String) throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        state.presentedFrame()
        state.presentedFrame()
        try finishExact(state)
        #expect(state.focusRestorationPending && state.hasAuthorizedFocusReturn)
        let request = try #require(state.focusReturnRequest)
        if focus == "shared" {
            state.observeFocusGain(rowID: "shared", generation: state.focusObservationGeneration, token: request.token)
            #expect(state.focusRestorationPending, "A native focus observation never completes the restoration by itself")
            state.acknowledgeFocusReturn(token: request.token)
            #expect(!state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
            #expect(state.focusedRowID == "shared")
            return
        }
        if focus == "different" {
            // A foreign token on the pending row's gain, and a foreign token's acknowledge, are
            // both stale observations: ignored, because only the matching token can consume or
            // confirm a focus request.
            state.acknowledgeFocusReturn(token: UUID())
            state.observeFocusGain(rowID: "shared", generation: state.focusObservationGeneration, token: UUID())
            #expect(state.focusReturnRequest == request && state.focusRestorationPending,
                    "Only the matching token can consume a focus request")
        }
        // The user moved keyboard focus away from the pending owner control.
        state.observeFocusLoss(rowID: "shared", generation: state.focusObservationGeneration, token: request.token)
        #expect(!state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
        #expect(state.focusedRowID == nil)
    }

    @Test func givenAuthorizedReturn_whenTheSameOwnerReturnsAgain_thenEachBackCycleIssuesAFreshSingleUseToken() throws {
        let state = savedState()
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        beginReturn(state)
        let first = try #require(state.focusReturnRequest)
        state.endAppearance()
        #expect(state.focusReturnRequest == nil, "Teardown invalidates the pending token")
        beginReturn(state)
        let second = try #require(state.focusReturnRequest)
        #expect(first.token != second.token && first.rowID == second.rowID)
        // The consumed token cannot be replayed by a later refresh or a duplicate callback.
        state.acknowledgeFocusReturn(token: second.token)
        #expect(!state.focusRestorationPending && state.focusReturnRequest == nil)
        state.acknowledgeFocusReturn(token: second.token)
        state.observeFocusGain(rowID: "shared", generation: state.focusObservationGeneration, token: second.token)
        #expect(!state.hasAuthorizedFocusReturn && state.focusedRowID == "shared")
    }

    @Test(arguments: ["budget", "cancel", "clear"])
    func givenPendingFocusRequest_whenInvalidatedAfterScrollSuccess_thenTheTokenDies(_ reason: String) throws {
        let state = savedState()
        departAndReturn(state)
        _ = try materializeOwner(state)
        state.presentedFrame()
        state.presentedFrame()
        try finishExact(state)
        try #require(state.focusReturnRequest != nil)
        if reason == "budget" {
            for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
                state.presentedFrame()
                if state.focusReturnRequest == nil { break }
            }
        } else if reason == "cancel" {
            state.cancelRestorationForUser()
        } else {
            state.clearFocusReturn()
        }
        #expect(state.focusReturnRequest == nil && !state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
        #expect(state.focusedRowID == nil)
    }

    @Test func givenNewerRestorationForTheSameOwner_whenStaleCallbacksFromAnEarlierBackCycleArrive_thenAllAreIgnored() throws {
        let state = savedState()
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        beginReturn(state)
        let stale = try #require(state.focusReturnRequest)
        let staleGeneration = state.focusObservationGeneration
        state.endAppearance()
        beginReturn(state)
        let current = try #require(state.focusReturnRequest)
        #expect(stale.token != current.token && staleGeneration != state.focusObservationGeneration)
        // A gain and a loss from the superseded appearance (its generation, its token), a loss
        // for another row under the current generation, and a stale acknowledge must all leave
        // the newer restoration untouched.
        state.observeFocusGain(rowID: "shared", generation: staleGeneration, token: stale.token)
        state.observeFocusLoss(rowID: "shared", generation: staleGeneration, token: stale.token)
        state.observeFocusLoss(rowID: "other", generation: state.focusObservationGeneration, token: current.token)
        state.acknowledgeFocusReturn(token: stale.token)
        #expect(state.focusReturnRequest == current)
        #expect(state.focusRestorationPending && state.hasAuthorizedFocusReturn)
        state.acknowledgeFocusReturn(token: current.token)
        #expect(state.focusReturnRequest == nil && !state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
    }

    @Test func givenRestoringOwner_whenAnEarlierOwnersGainCarriesAStaleOrNilGeneration_thenItIsIgnored() throws {
        let state = savedState()
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        beginReturn(state)
        let stale = try #require(state.focusReturnRequest)
        let staleGeneration = state.focusObservationGeneration
        state.endAppearance()
        beginReturn(state)
        let current = try #require(state.focusReturnRequest)
        #expect(stale.token != current.token && staleGeneration != state.focusObservationGeneration && state.isRestoring)
        // An earlier appearance's gain — carrying its superseded generation, or the nil
        // generation a dismantled control reports — must neither cancel the newer restoration
        // nor reassign the focused row.
        state.observeFocusGain(rowID: "other", generation: staleGeneration, token: stale.token)
        state.observeFocusGain(rowID: "other", generation: nil, token: nil)
        #expect(state.isRestoring && state.restorationOutcome == nil && state.focusedRowID == "shared")
        #expect(state.focusReturnRequest == current)
        // Only a current-generation gain from a different row counts as user focus movement.
        state.observeFocusGain(rowID: "other", generation: state.focusObservationGeneration, token: current.token)
        #expect(state.restorationOutcome == .userCancelled && state.focusedRowID == "other")
    }

    @Test func givenSidebarReturnWithoutOwnerIntent_whenPointSettles_thenFocusRemainsUnclaimed() {
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.update(geometry(250), ready: true)
        state.setSelected(false)
        state.endAppearance()
        state.setSelected(true)
        state.beginAppearance()
        state.update(geometry(250), ready: true)
        for _ in 0 ..< 4 {
            state.presentedFrame()
        }
        #expect(state.restorationOutcome == .exact && state.retainedOffset == 250)
        #expect(!state.focusRestorationPending && !state.hasAuthorizedFocusReturn)
    }

    @Test func givenSameLoadingTransition_whenRemountedThenANewLoadBegins_thenOnlyTheNewTransitionAnnouncesAgain() {
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        #expect(state.takeLoadingAnnouncement(isLoading: true))
        #expect(!state.takeLoadingAnnouncement(isLoading: true))
        state.endAppearance()
        state.setSelected(true)
        state.beginAppearance()
        #expect(!state.takeLoadingAnnouncement(isLoading: true))
        #expect(!state.takeLoadingAnnouncement(isLoading: false))
        #expect(state.takeLoadingAnnouncement(isLoading: true))
    }

    @Test func givenDomainIDsCollideAcrossGroupAndOwner_whenPresentationIsRebuilt_thenListTargetsStayDistinctAndStable() throws {
        let original = group()
        let rebuilt = group()
        let owner = try #require(original.holders.first)
        let rebuiltOwner = try #require(rebuilt.holders.first)
        try #require(original.id == owner.id, "Fixture must exercise equal raw domain identifiers")
        #expect(original.scrollTarget != owner.scrollTarget)
        #expect(original.scrollTarget == rebuilt.scrollTarget && owner.scrollTarget == rebuiltOwner.scrollTarget)
        #expect(Set([original.scrollTarget, owner.scrollTarget]).count == 2)
        #expect(owner.scrollTarget == .owner(owner.id) && original.scrollTarget == .group(original.id))
    }

    private func savedState() -> ResourceSlotsReadingState {
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.reconcile(groups: [group()], expandedResourceIDs: ["shared"])
        updateOwner(state, offset: 2500, contentY: 2597)
        return state
    }

    private func departAndReturn(_ state: ResourceSlotsReadingState) {
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        beginReturn(state)
    }

    private func beginReturn(_ state: ResourceSlotsReadingState, ready: Bool = true) {
        state.setSelected(true)
        state.authorizeFocusReturn()
        state.beginAppearance(ready: ready)
        state.reconcile(groups: [group()], expandedResourceIDs: ["shared"])
    }

    private func materializeOwner(_ state: ResourceSlotsReadingState) throws -> [ResourceSlotsIDScrollRequest] {
        state.update(geometry(0, contentHeight: 500), ready: true)
        state.presentedFrame()
        let groupRequest = try #require(state.idScrollRequest)
        try #require(groupRequest.target == .group("shared"))
        try #require(state.consumeIDScrollRequest(groupRequest))
        #expect(!state.consumeIDScrollRequest(groupRequest), "A proxy command executes only once")
        state.update(geometry(97), ready: true)
        state.updateGroup(groupID: "shared", frames: frames(contentY: 97, offset: 97, height: 7000))
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.idScrollRequest == nil && state.pointRequestCount == 0, "ID and point channels cannot both issue in one frame")
        state.presentedFrame()
        let ownerRequest = try #require(state.idScrollRequest)
        try #require(ownerRequest.target == .owner("shared"))
        try #require(state.consumeIDScrollRequest(ownerRequest))
        updateOwner(state, offset: 2597, contentY: 2597)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.idScrollRequest == nil && state.pointRequestCount == 0)
        #expect(!state.consumeIDScrollRequest(groupRequest) && !state.consumeIDScrollRequest(ownerRequest))
        return [groupRequest, ownerRequest]
    }

    private func finishExact(_ state: ResourceSlotsReadingState) throws {
        updateOwner(state, offset: 2500, contentY: 2597)
        state.presentedFrame()
        #expect(state.isRestoring)
        state.presentedFrame()
        try #require(state.restorationOutcome == .exact)
    }

    private func updateOwner(_ state: ResourceSlotsReadingState, offset: CGFloat, contentY: CGFloat, contentHeight: CGFloat = 8000) {
        state.update(geometry(offset, contentHeight: contentHeight), ready: true)
        state.updateOwner(rowID: "shared", groupID: "shared", frames: frames(contentY: contentY, offset: offset))
    }

    private func geometry(_ offset: CGFloat, contentHeight: CGFloat = 8000, topInset: CGFloat = 0, bottomInset: CGFloat = 0) -> ResourceSlotsScrollGeometry {
        .init(offset: offset, contentHeight: contentHeight, viewportHeight: 400, topInset: topInset, bottomInset: bottomInset)
    }

    private func frames(contentY: CGFloat, offset: CGFloat, height: CGFloat = 64) -> ResourceSlotsDiagnosticFrames {
        .init(viewport: CGRect(x: 0, y: contentY - offset, width: 120, height: height),
              content: CGRect(x: 0, y: contentY, width: 120, height: height))
    }

    private func group(includeOwner: Bool = true) -> ResourceSlotsGroup {
        let owner = ResourceSlotsOwner(id: "shared", title: "Owner", ownerID: "owner", status: "Held", since: nil,
                                       detail: nil, position: nil, action: .init(label: "Open task", ownerID: "owner"), blockers: nil)
        return .init(id: "shared", title: "Resource", capacitySummary: "1 of 1 in use", holderHeading: "Holders",
                     holders: includeOwner ? [owner] : [], emptyHolderMessage: nil, waiterHeading: nil, waiters: [])
    }
}
