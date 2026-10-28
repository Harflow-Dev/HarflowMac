@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - WorkflowAgentEditorTests

struct WorkflowAgentEditorTests {
    @Test func givenVibeCandidate_whenEdited_thenModelAndEffortControlsStayUnavailable() {
        // given / when / then — vibe's model and effort are config-only; the editor never
        // offers controls the backend would silently ignore.
        #expect(!WorkflowAgentEditorPresentation.showsModelAndEffort(backend: "vibe"))
        #expect(WorkflowAgentEditorPresentation.showsModelAndEffort(backend: "codex"))
        #expect(WorkflowAgentEditorPresentation.showsModelAndEffort(backend: "claude"))
        #expect(WorkflowAgentEditorPresentation.showsModel(backend: "cursor"))
        #expect(!WorkflowAgentEditorPresentation.showsEffort(backend: "cursor"))
        #expect(WorkflowAgentEditorPresentation.showsEffort(backend: "codex"))
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
}
