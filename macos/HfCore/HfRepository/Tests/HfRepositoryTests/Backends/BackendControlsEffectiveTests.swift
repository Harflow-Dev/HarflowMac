import Foundation
@testable import HfRepository
import Testing

struct BackendControlsEffectiveTests {
    private func harness(_ effort: EffortState, model: ControlState = .supported, turnCap: ControlState = .supported) -> BackendControls {
        BackendControls(model: model, effort: effort, turnCap: turnCap)
    }

    private func effective(_ effort: EffortState, _ modelLevels: [String]?) -> EffortState {
        BackendControls.effectiveControls(harness: harness(effort), modelEffortLevels: modelLevels).effort
    }

    // MARK: Harness reports levels

    @Test func givenHarnessLevels_whenModelSaysNothing_thenHarnessControlsAreUnchanged() {
        // given
        let controls = harness(.levels(["low", "medium", "high"]))

        // when / then
        #expect(BackendControls.effectiveControls(harness: controls, modelEffortLevels: nil) == controls)
    }

    @Test func givenHarnessLevels_whenModelListsNoSelectableLevel_thenEffortIsUnsupported() {
        #expect(effective(.levels(["low", "high"]), []) == .unsupported)
    }

    @Test func givenHarnessLevels_whenModelListsASubset_thenOnlyThoseRemain() {
        #expect(effective(.levels(["low", "medium", "high"]), ["low", "high"]) == .levels(["low", "high"]))
    }

    @Test func givenHarnessLevels_whenModelListsThemInAnotherOrder_thenHarnessOrderIsKept() {
        #expect(effective(.levels(["low", "medium", "high"]), ["high", "low", "medium"]) == .levels(["low", "medium", "high"]))
    }

    @Test func givenHarnessLevels_whenModelListsAPartialOverlap_thenOnlyTheSharedLevelsRemain() {
        #expect(effective(.levels(["low", "medium", "high"]), ["medium", "xhigh"]) == .levels(["medium"]))
    }

    @Test func givenHarnessLevels_whenModelListsOnlyOtherLevels_thenEffortIsUnsupported() {
        #expect(effective(.levels(["low", "medium"]), ["high", "xhigh"]) == .unsupported)
    }

    @Test func givenHarnessLevels_whenModelListsASupersetOfThem_thenItNeverWidensTheHarness() {
        #expect(effective(.levels(["low", "high"]), ["minimal", "low", "medium", "high", "xhigh"]) == .levels(["low", "high"]))
    }

    @Test func givenHarnessLevels_whenModelRepeatsALevel_thenTheResultHasNoDuplicates() {
        #expect(effective(.levels(["low", "high"]), ["high", "high", "low"]) == .levels(["low", "high"]))
    }

    // MARK: Harness reports no levels

    @Test(arguments: [nil, [], ["low"], ["low", "high"]] as [[String]?])
    func givenUnsupportedHarnessEffort_whenModelListsLevels_thenItStaysUnsupported(_ modelLevels: [String]?) {
        #expect(effective(.unsupported, modelLevels) == .unsupported)
    }

    @Test(arguments: [nil, [], ["low"], ["low", "high"]] as [[String]?])
    func givenUnknownHarnessEffort_whenModelListsLevels_thenItStaysUnknown(_ modelLevels: [String]?) {
        #expect(effective(.unknown, modelLevels) == .unknown)
    }

    // MARK: Other controls

    @Test func givenAnyModelLevels_whenResolved_thenModelAndTurnCapStatesAreUntouched() {
        // given
        let controls = harness(.levels(["low", "high"]), model: .unknown, turnCap: .unsupported)

        // when
        let resolved = BackendControls.effectiveControls(harness: controls, modelEffortLevels: ["low"])

        // then
        #expect(resolved.model == .unknown)
        #expect(resolved.turnCap == .unsupported)
        #expect(resolved.effort == .levels(["low"]))
    }

    @Test func givenCachedModelLevels_whenTheHarnessLevelsChange_thenTheResultFollowsTheCurrentHarness() {
        // given
        let cached = ["low", "medium"]

        // when / then
        #expect(effective(.levels(["low", "medium", "high"]), cached) == .levels(["low", "medium"]))
        #expect(effective(.levels(["medium", "high"]), cached) == .levels(["medium"]))
        #expect(effective(.levels(["high"]), cached) == .unsupported)
        #expect(effective(.unknown, cached) == .unknown)
        #expect(effective(.unsupported, cached) == .unsupported)
    }
}
