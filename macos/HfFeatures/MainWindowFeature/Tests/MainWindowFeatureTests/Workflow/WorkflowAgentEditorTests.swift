import HfRepository
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowAgentEditorTests

struct WorkflowAgentEditorTests {
    private func controls(_ name: String) -> BackendControls { BackendControls(facts: BackendControlFixtures.facts(for: name)) }

    @Test func givenEngineControls_whenRowsAreDecided_thenOnlyUnsupportedControlsAreHidden() {
        // given
        let empty: [String: JSONValue] = [:]
        let vibe = controls("vibe")
        // when / then
        #expect(!WorkflowAgentEditorPresentation.showsModel(vibe, candidate: empty))
        #expect(!WorkflowAgentEditorPresentation.showsEffort(vibe, candidate: empty))
        #expect(WorkflowAgentEditorPresentation.showsTurnLimit(vibe, candidate: empty))
        let cursor = controls("cursor")
        #expect(WorkflowAgentEditorPresentation.showsModel(cursor, candidate: empty))
        #expect(!WorkflowAgentEditorPresentation.showsEffort(cursor, candidate: empty))
        #expect(!WorkflowAgentEditorPresentation.showsTurnLimit(cursor, candidate: empty))
        let codex = controls("codex")
        #expect(WorkflowAgentEditorPresentation.showsEffort(codex, candidate: empty))
        // effort no longer depends on the model row
        let effortOnly = BackendControls(model: .unsupported, effort: .levels(["low"]), turnCap: .unsupported)
        #expect(WorkflowAgentEditorPresentation.showsEffort(effortOnly, candidate: empty))
        #expect(!WorkflowAgentEditorPresentation.showsModel(effortOnly, candidate: empty))
    }

    @Test func givenUnknownControls_whenRowsAreDecided_thenAllRowsShow() {
        // given / when / then
        for unknown in [BackendControls.unavailable] {
            #expect(WorkflowAgentEditorPresentation.showsModel(unknown, candidate: [:]))
            #expect(WorkflowAgentEditorPresentation.showsEffort(unknown, candidate: [:]))
            #expect(WorkflowAgentEditorPresentation.showsTurnLimit(unknown, candidate: [:]))
        }
    }

    @Test func givenASavedValueForAnUnsupportedControl_whenRowsAreDecided_thenItStaysVisible() {
        // given
        let vibe = controls("vibe")
        let saved: [String: JSONValue] = ["model": .string("m"), "reasoning_effort": .string("high")]
        // when / then
        #expect(WorkflowAgentEditorPresentation.showsModel(vibe, candidate: saved))
        #expect(WorkflowAgentEditorPresentation.showsEffort(vibe, candidate: saved))
        let cursor = controls("cursor")
        #expect(WorkflowAgentEditorPresentation.showsTurnLimit(cursor, candidate: ["max_turns": .number(3)]))
    }

    @Test func givenEngineLevels_whenEffortMenuIsBuilt_thenDefaultThenExactlyThoseLevelsInOrder() {
        // given / when
        let options = WorkflowAgentEditorPresentation.effortOptions(controls("antigravity"), saved: "")
        // then
        #expect(options.map(\.value) == ["", "low", "medium", "high"])
        #expect(options.map(\.title) == ["Default", "Low", "Medium", "High"])
    }

    @Test func givenASavedEffortOutsideTheLevels_whenMenuIsBuilt_thenItIsMarkedUnavailable() {
        // given / when
        let options = WorkflowAgentEditorPresentation.effortOptions(controls("antigravity"), saved: "xhigh")
        // then
        #expect(options.last == .init(value: "xhigh", title: "xhigh — unavailable for this harness"))
        #expect(options.count == 5)
    }

    @Test func givenUnknownEffort_whenMenuIsBuilt_thenDefaultPlusTheSavedValueOnly() {
        // given / when
        let none = WorkflowAgentEditorPresentation.effortOptions(.unavailable, saved: "")
        let saved = WorkflowAgentEditorPresentation.effortOptions(.unavailable, saved: "high")
        // then — levels are never invented
        #expect(none.map(\.value) == [""])
        #expect(saved.map(\.value) == ["", "high"])
        #expect(saved.last?.title == "High")
    }

    @Test func givenCustomModelEntry_whenApplied_thenEmptyRevertsToDefaultAndTextIsKept() {
        // given / when / then
        #expect(WorkflowAgentEditorPresentation.modelValue("") == nil)
        #expect(WorkflowAgentEditorPresentation.modelValue("opus") == .string("opus"))
    }

    @Test func givenSupportedPreferredBackend_whenOptionsAreBuilt_thenItLeadsOnceAheadOfFrequencyOrder() {
        let options = WorkflowAgentEditorPresentation.backendOptions(
            ["codex", "codex", "claude"], current: "claude", preferred: "claude")

        #expect(options == ["claude", "codex"])
    }

    @Test func givenUnavailablePreferredBackend_whenOptionsAreBuilt_thenCurrentSelectionIsRetainedWithoutDuplicates() {
        let options = WorkflowAgentEditorPresentation.backendOptions(
            ["codex", "codex"], current: "claude", preferred: "vibe")

        #expect(options == ["codex", "claude"])
    }

    @Test func givenSupportedPreferredModelAcrossBackends_whenModelMenuIsBuilt_thenExactModelLeadsDefault() {
        let options = WorkflowAgentEditorPresentation.modelOptions(
            [
                ModelChoiceModel(id: "", title: "Default"),
                ModelChoiceModel(id: "gpt-5", title: "GPT-5"),
                ModelChoiceModel(id: "gpt-5", title: "Duplicate GPT-5")
            ], preferred: "gpt-5")

        #expect(options.map(\.id) == ["gpt-5", ""])
        #expect(options.first?.title == "GPT-5")
    }

    @Test func givenIncompatiblePreferredModel_whenEditorOptionsAreBuilt_thenSelectionAndCandidateRemainUnchanged() {
        let candidate: [String: JSONValue] = ["backend": .string("vibe"), "model": .string("custom")]
        let options = WorkflowAgentEditorPresentation.modelOptions(
            [ModelChoiceModel(id: "", title: "Default"), ModelChoiceModel(id: "gpt-5", title: "GPT-5")],
            preferred: "claude-opus")
        let backends = WorkflowAgentEditorPresentation.backendOptions(
            ["vibe", "vibe", "codex"], current: candidate["backend"]?.stringValue ?? "", preferred: "claude")

        #expect(options.map(\.id) == ["", "gpt-5"])
        #expect(backends == ["vibe", "codex"])
        #expect(candidate["backend"]?.stringValue == "vibe")
        #expect(candidate["model"]?.stringValue == "custom")
    }

    @Test func givenOrderedFallbacks_whenAdded_thenNewFallbackAppendsLast() {
        // given
        var candidate: [String: JSONValue] = ["backend": .string("codex")]
        // when
        candidate = WorkflowAgentEditorOperations.addingFallback(to: candidate, backendIDs: ["claude"])
        candidate = WorkflowAgentEditorOperations.addingFallback(to: candidate, backendIDs: ["vibe"])
        // then
        #expect(WorkflowAgentEditorOperations.fallbacks(candidate).map { $0["backend"]?.stringValue } == ["claude", "vibe"])
    }

    @Test func givenOrderedFallbacks_whenReordered_thenOnlyTheRequestedPairSwaps() {
        // given
        var candidate: [String: JSONValue] = ["backend": .string("codex")]
        for backend in ["claude", "vibe", "opencode"] {
            candidate = WorkflowAgentEditorOperations.addingFallback(to: candidate, backendIDs: [backend])
        }
        // when
        candidate = WorkflowAgentEditorOperations.movingFallback(at: 2, by: -1, in: candidate)
        // then
        #expect(WorkflowAgentEditorOperations.fallbacks(candidate).map { $0["backend"]?.stringValue }
                == ["claude", "opencode", "vibe"])
        // when — out-of-range moves leave the order untouched
        candidate = WorkflowAgentEditorOperations.movingFallback(at: 0, by: -1, in: candidate)
        candidate = WorkflowAgentEditorOperations.movingFallback(at: 2, by: 1, in: candidate)
        // then
        #expect(WorkflowAgentEditorOperations.fallbacks(candidate).map { $0["backend"]?.stringValue }
                == ["claude", "opencode", "vibe"])
    }

    @Test func givenOrderedFallbacks_whenRemoved_thenRemainingOrderIsPreserved() {
        // given
        var candidate: [String: JSONValue] = ["backend": .string("codex")]
        for backend in ["claude", "vibe", "opencode"] {
            candidate = WorkflowAgentEditorOperations.addingFallback(to: candidate, backendIDs: [backend])
        }
        // when
        candidate = WorkflowAgentEditorOperations.removingFallback(at: 1, in: candidate)
        // then
        #expect(WorkflowAgentEditorOperations.fallbacks(candidate).map { $0["backend"]?.stringValue }
                == ["claude", "opencode"])
        // when — an out-of-range removal is a no-op
        candidate = WorkflowAgentEditorOperations.removingFallback(at: 9, in: candidate)
        // then
        #expect(WorkflowAgentEditorOperations.fallbacks(candidate).count == 2)
    }

    @Test func givenASavedModelOnAnUnsupportedControl_whenCaptionIsDecided_thenUnavailableCaptionShows() {
        // given
        let vibe = controls("vibe")
        // when / then — the row is visible only because a value is saved, and says so
        #expect(WorkflowAgentEditorPresentation.showsModel(vibe, candidate: ["model": .string("m")]))
        #expect(WorkflowAgentEditorPresentation.showsUnavailableCaption(vibe.model))
        #expect(!WorkflowAgentEditorPresentation.showsUnavailableCaption(controls("claude").model))
        #expect(!WorkflowAgentEditorPresentation.showsUnavailableCaption(.unknown))
        #expect(WorkflowAgentEditorPresentation.unavailableCaption == "Unavailable for this harness")
    }

    @Test func givenSavedMaxTurns_whenPickerSwitchesCodexToClaudeWithAvailableCatalog_thenItIsKept() {
        // given
        let candidate: [String: JSONValue] = ["backend": .string("codex"), "max_turns": .number(9)]
        let available = BackendControlFixtures.controls("codex", "claude")
        // when
        let switched = WorkflowAgentEditorPresentation.replacingBackend(
            in: candidate, with: "claude", callerApprovalBackends: [], backendControls: available)
        // then
        #expect(switched["backend"] == .string("claude"))
        #expect(switched["max_turns"] == .number(9))
    }

    @Test func givenSavedMaxTurns_whenPickerSwitchesCodexToClaudeWhileCatalogLoads_thenItIsCleared() {
        // given
        let candidate: [String: JSONValue] = ["backend": .string("codex"), "max_turns": .number(9)]
        // when — a loading catalog has no controls for the new harness
        let switched = WorkflowAgentEditorPresentation.replacingBackend(
            in: candidate, with: "claude", callerApprovalBackends: [], backendControls: [:])
        // then
        #expect(switched["max_turns"] == nil)
    }
}
