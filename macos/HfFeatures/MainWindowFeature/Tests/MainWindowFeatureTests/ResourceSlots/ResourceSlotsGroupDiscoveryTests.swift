import Foundation
@testable import MainWindowFeature
import Testing

@MainActor
struct ResourceSlotsGroupDiscoveryTests {
    @Test func givenLazyExtentGrowsBeforeConsumption_whenMissingGroupSettles_thenOnlyGrowthFromConsumptionAllowsOneRetry() throws {
        let state = returningState()
        state.update(geometry(height: 800), ready: true)
        state.presentedFrame()
        let first = try #require(state.idScrollRequest)
        state.update(geometry(height: 1000), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.idScrollRequest == first, "Unconsumed commands cannot overlap or trigger another issue")
        try #require(state.consumeIDScrollRequest(first))
        for _ in 0 ..< 3 { state.presentedFrame() }
        #expect(state.idScrollRequest == nil, "Issue-time extent800 must not replace actual consumption extent1000")
        state.update(geometry(height: 1001), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        #expect(state.idScrollRequest == nil, "One point of extent variation does not establish material lazy growth")
        state.update(geometry(height: 1500), ready: true)
        let framesBefore = state.restorationFrames
        state.presentedFrame()
        #expect(state.idScrollRequest == nil)
        state.presentedFrame()
        let retry = try #require(state.idScrollRequest, "A missing target must settle independently of the target-coherence sampler")
        #expect(retry.target == first.target && retry.generation == first.generation && retry.id != first.id)
        #expect(state.restorationFrames == framesBefore + 2 && state.pointRequestCount == 0)
        #expect(!state.consumeIDScrollRequest(first))
        #expect(state.consumeIDScrollRequest(retry) && !state.consumeIDScrollRequest(retry))
    }

    @Test func givenMissingGroupAndChangingGeometry_whenTwoCurrentSamplesFinallyAgree_thenOldStableSamplesCannotQualifyTheRetry() throws {
        let state = returningState()
        _ = try consumeFirst(state)
        state.update(geometry(height: 1500, offset: 20), ready: true)
        state.presentedFrame()
        state.update(geometry(height: 1500, offset: 21), ready: true)
        state.presentedFrame()
        #expect(state.idScrollRequest == nil)
        state.presentedFrame()
        #expect(state.idScrollRequest?.target == .group("shared"))
        #expect(state.pointRequestCount == 0)
    }

    @Test(arguments: [800.0, 1000.0, 1001.0])
    func givenConsumedGroupCommand_whenExtentShrinksOrDoesNotMateriallyGrow_thenThereIsNoRetry(_ height: Double) throws {
        let state = returningState()
        _ = try consumeFirst(state)
        state.update(geometry(height: height), ready: true)
        for _ in 0 ..< 6 { state.presentedFrame() }
        #expect(state.idScrollRequest == nil && state.pointRequestCount == 0 && state.isRestoring)
    }

    @Test(arguments: ["offscreen", "incoherent", "visible"])
    func givenAGroupHasAnAcceptedFrame_whenItsExtentGrows_thenMissingOnlyRetryDoesNotWidenQualification(_ placement: String) throws {
        let state = returningState()
        _ = try consumeFirst(state)
        state.update(geometry(height: 3000, offset: 20), ready: true)
        let contentY: CGFloat = placement == "offscreen" ? 1000 : 20
        let viewportY: CGFloat = placement == "incoherent" ? 49 : contentY - 20
        state.updateGroup(groupID: "shared", frames: .init(
            viewport: CGRect(x: 0, y: viewportY, width: 200, height: 100),
            content: CGRect(x: 0, y: contentY, width: 200, height: 100)
        ))
        for _ in 0 ..< 8 {
            state.presentedFrame()
            if let command = state.idScrollRequest {
                #expect(command.target == .owner("shared"), "A realized group must never receive the missing-target retry")
                #expect(state.consumeIDScrollRequest(command))
            }
        }
        #expect(state.pointRequestCount == 0 && state.isRestoring)
    }

    @Test func givenTwoGroupIssues_whenReadinessAndOwnerPhaseReenterCollapsedGroup_thenTheLedgerAndFrameBudgetCannotReset() throws {
        let state = returningState()
        _ = try consumeFirst(state)
        let second = try issueRetry(state)
        try #require(state.consumeIDScrollRequest(second))
        let framesBefore = state.restorationFrames
        state.setReady(false)
        for _ in 0 ..< 4 { state.presentedFrame() }
        #expect(state.restorationFrames == framesBefore)
        state.setReady(true)
        state.update(geometry(height: 3000, offset: 20), ready: true)
        for _ in 0 ..< 3 { state.presentedFrame() }
        #expect(state.idScrollRequest == nil)
        state.updateGroup(groupID: "shared", frames: .init(
            viewport: CGRect(x: 0, y: 0, width: 200, height: 1000),
            content: CGRect(x: 0, y: 20, width: 200, height: 1000)
        ))
        state.presentedFrame()
        state.presentedFrame()
        state.presentedFrame()
        let owner = try #require(state.idScrollRequest)
        try #require(owner.target == .owner("shared") && state.consumeIDScrollRequest(owner))
        state.reconcile(groups: [group()], expandedResourceIDs: [])
        state.removeGroup(groupID: "shared")
        state.update(geometry(height: 5000, offset: 20), ready: true)
        for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            state.presentedFrame()
            #expect(state.idScrollRequest == nil, "Collapse/phase reentry cannot replenish a third group issue")
            #expect(state.pointRequestCount == 0, "Missing geometry cannot bypass discovery through a point request")
        }
        #expect(state.restorationOutcome == .fallback && !state.isRestoring)
        #expect(state.restorationFrames <= 64 && state.restorationFrames >= framesBefore)
    }

    @Test func givenConsumedRetry_whenExtentKeepsGrowing_thenCommandsReachTheCapButNeverExceedIt() throws {
        let state = returningState()
        _ = try consumeFirst(state)
        let retry = try issueRetry(state)
        try #require(state.consumeIDScrollRequest(retry), "The retry command executes once")
        state.update(geometry(height: 9000), ready: true)
        for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            state.presentedFrame()
            #expect(state.idScrollRequest == nil,
                    "A command beyond maximumGroupDiscoveryCommands must never be issued, even under further growth")
        }
        #expect(state.restorationOutcome == .fallback && !state.isRestoring)
        #expect(state.restorationFrames <= ResourceSlotsReadingState.maximumRestorationFrames)
        #expect(state.pointRequestCount == 0)
    }

    @Test func givenConsumedGroupCommand_whenExtentIsUnchanged_thenNoRetryIsEverIssued() throws {
        let state = returningState()
        _ = try consumeFirst(state)
        for _ in 0 ..< ResourceSlotsReadingState.maximumRestorationFrames {
            state.presentedFrame()
            #expect(state.idScrollRequest == nil, "An unchanged extent after a consumption never qualifies a retry")
        }
        #expect(state.restorationOutcome == .fallback && !state.isRestoring)
        #expect(state.pointRequestCount == 0)
    }

    @Test(arguments: ["readiness", "user", "runtime", "unmount", "removed"])
    func givenConsumedFirstIssue_whenEligibilityIsInvalidated_thenGrowthCannotUseItsObsoleteBaseline(_ reason: String) throws {
        let state = returningState()
        let first = try consumeFirst(state)
        if reason == "readiness" { state.setReady(false); state.setReady(true) }
        if reason == "user" { state.cancelRestorationForUser() }
        if reason == "runtime" { state.resetForRuntime() }
        if reason == "unmount" { state.endAppearance() }
        if reason == "removed" { state.reconcile(groups: [], expandedResourceIDs: []) }
        state.update(geometry(height: 2500), ready: true)
        for _ in 0 ..< 5 { state.presentedFrame() }
        #expect(!state.consumeIDScrollRequest(first))
        #expect(state.idScrollRequest == nil && state.pointRequestCount == 0)
    }

    @Test func givenPendingRetry_whenUnmountedAndMountedAgain_thenItsGenerationCannotExecuteAgainstTheFreshAppearance() throws {
        let state = returningState()
        _ = try consumeFirst(state)
        let obsolete = try issueRetry(state)
        state.endAppearance()
        state.setSelected(true)
        state.beginAppearance()
        state.reconcile(groups: [group()], expandedResourceIDs: ["shared"])
        state.update(geometry(height: 1000), ready: true)
        state.presentedFrame()
        let fresh = try #require(state.idScrollRequest)
        #expect(fresh.generation != obsolete.generation && fresh.id != obsolete.id)
        #expect(!state.consumeIDScrollRequest(obsolete) && state.consumeIDScrollRequest(fresh))
        #expect(state.pointRequestCount == 0)
    }

    private func consumeFirst(_ state: ResourceSlotsReadingState) throws -> ResourceSlotsIDScrollRequest {
        state.update(geometry(height: 1000), ready: true)
        state.presentedFrame()
        let command = try #require(state.idScrollRequest)
        try #require(command.target == .group("shared") && state.consumeIDScrollRequest(command))
        return command
    }

    private func issueRetry(_ state: ResourceSlotsReadingState) throws -> ResourceSlotsIDScrollRequest {
        state.update(geometry(height: 1500), ready: true)
        state.presentedFrame()
        state.presentedFrame()
        return try #require(state.idScrollRequest)
    }

    private func returningState() -> ResourceSlotsReadingState {
        let state = ResourceSlotsReadingState()
        state.beginAppearance()
        state.reconcile(groups: [group()], expandedResourceIDs: ["shared"])
        state.update(geometry(height: 8000, offset: 2500), ready: true)
        state.updateOwner(rowID: "shared", groupID: "shared", frames: .init(
            viewport: CGRect(x: 0, y: 97, width: 200, height: 64),
            content: CGRect(x: 0, y: 2597, width: 200, height: 64)
        ))
        state.prepareDeparture(ownerRowID: "shared")
        state.endAppearance()
        state.setSelected(true)
        state.authorizeFocusReturn()
        state.beginAppearance()
        state.reconcile(groups: [group()], expandedResourceIDs: ["shared"])
        return state
    }

    private func geometry(height: CGFloat, offset: CGFloat = 0) -> ResourceSlotsScrollGeometry {
        .init(offset: offset, contentHeight: height, viewportHeight: 400)
    }

    private func group() -> ResourceSlotsGroup {
        let owner = ResourceSlotsOwner(id: "shared", title: "Owner", ownerID: "owner", status: "Held", since: nil,
                                       detail: nil, position: nil, action: .init(label: "Open task", ownerID: "owner"), blockers: nil)
        return .init(id: "shared", title: "Resource", capacitySummary: "1 of 1 in use", holderHeading: "Holders", holders: [owner],
                     emptyHolderMessage: nil, waiterHeading: nil, waiters: [])
    }
}
