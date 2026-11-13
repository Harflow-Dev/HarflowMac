import Foundation
@testable import HfRepository
import MonitorCore
import Testing

struct BackendCatalogControlsTests {
    private func catalog(_ state: BackendCatalogState, _ facts: BackendControlFacts, backend: String = "h") -> BackendCatalog {
        BackendCatalog(entries: [BackendCatalogEntry(backend: backend, installed: true, controls: facts)], state: state)
    }

    private func facts(
        model: Bool? = true,
        gate: BackendControlFacts.ModelSelectionGate = .notDeclared,
        turn: Bool? = true,
        effort: BackendControlFacts.Effort? = .init(acceptsParameter: true, levels: ["low", "high"])
    ) -> BackendControlFacts {
        BackendControlFacts(supportsModelSelection: model, supportsTurnCap: turn, effort: effort, modelSelection: gate)
    }

    @Test func givenLoadingDegradedAndUnlistedBackend_whenAskingForControls_thenUnavailable() {
        // given / when / then
        #expect(catalog(.loading, facts()).controls(for: "h") == .unavailable)
        #expect(catalog(.degraded, facts()).controls(for: "h") == .unavailable)
        #expect(catalog(.available, facts()).controls(for: "other") == .unavailable)
        #expect(BackendCatalog.empty.controls(for: "h") == .unavailable)
    }

    @Test func givenAnAvailableCatalog_whenFactsAreSupported_thenControlsAreSupportedInEngineOrder() {
        // given / when
        let controls = catalog(.available, facts()).controls(for: "h")
        // then
        #expect(controls == BackendControls(model: .supported, effort: .levels(["low", "high"]), turnCap: .supported))
    }

    @Test func givenModelSelectionFactsAndGates_whenMapped_thenTruthTableHolds() {
        // given
        let cases: [(Bool?, BackendControlFacts.ModelSelectionGate, ControlState)] = [
            (true, .notDeclared, .supported), (true, .ready, .supported),
            (true, .notReady, .unsupported), (true, .unknown, .unknown),
            (false, .notDeclared, .unsupported), (false, .ready, .unsupported),
            (false, .unknown, .unsupported), (nil, .ready, .unknown), (nil, .notDeclared, .unknown)
        ]
        // when / then
        for (flag, gate, expected) in cases {
            #expect(BackendControls(facts: facts(model: flag, gate: gate)).model == expected, "\(String(describing: flag)) \(gate)")
        }
    }

    @Test func givenEffortFacts_whenMapped_thenLevelsUnsupportedOrUnknown() {
        // given / when / then
        #expect(BackendControls(facts: facts(effort: nil)).effort == .unknown)
        #expect(BackendControls(facts: facts(effort: .init(acceptsParameter: false, levels: []))).effort == .unsupported)
        #expect(BackendControls(facts: facts(effort: .init(acceptsParameter: false, levels: ["low"]))).effort == .unsupported)
        #expect(BackendControls(facts: facts(effort: .init(acceptsParameter: true, levels: []))).effort == .unsupported)
        #expect(BackendControls(facts: facts(effort: .init(acceptsParameter: true, levels: ["max", "low"]))).effort == .levels(["max", "low"]))
    }

    @Test func givenTurnCapFacts_whenMapped_thenThreeStates() {
        // given / when / then
        #expect(BackendControls(facts: facts(turn: true)).turnCap == .supported)
        #expect(BackendControls(facts: facts(turn: false)).turnCap == .unsupported)
        #expect(BackendControls(facts: facts(turn: nil)).turnCap == .unknown)
    }
}
