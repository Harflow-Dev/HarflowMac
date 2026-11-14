import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowModelEffortPresentationTests

/// A workflow node's Effort row follows the node's own saved model, narrowed against the harness.
struct WorkflowModelEffortPresentationTests {
    private let harness = BackendControls(model: .supported, effort: .levels(["low", "medium", "high"]), turnCap: .unsupported)
    private let choices = [
        ModelChoiceModel(id: "", title: "Default", effortLevels: ["low"]),
        ModelChoiceModel(id: "subset", title: "Subset", effortLevels: ["high", "low"]),
        ModelChoiceModel(id: "none", title: "None", effortLevels: []),
        ModelChoiceModel(id: "silent", title: "Silent", effortLevels: nil),
        ModelChoiceModel(id: "disjoint", title: "Disjoint", effortLevels: ["xhigh"])
    ]

    private func candidate(model: String? = nil, effort: String? = nil) -> [String: JSONValue] {
        var value: [String: JSONValue] = ["backend": .string("codex")]
        if let model { value["model"] = .string(model) }
        if let effort { value["reasoning_effort"] = .string(effort) }
        return value
    }

    private func effective(_ node: [String: JSONValue], harness override: BackendControls? = nil) -> BackendControls {
        WorkflowAgentEditorPresentation.effectiveControls(override ?? harness, candidate: node, choices: choices)
    }

    // MARK: Matched model

    @Test func givenASavedModelListingASubset_whenEffortIsPresented_thenTheMenuHoldsDefaultAndTheSharedLevelsInHarnessOrder() {
        // given
        let node = candidate(model: "subset")

        // when
        let controls = effective(node)

        // then
        #expect(WorkflowAgentEditorPresentation.showsEffort(controls, candidate: node))
        #expect(WorkflowAgentEditorPresentation.effortOptions(controls, saved: "").map(\.value) == ["", "low", "high"])
    }

    @Test func givenASavedModelListingNoSelectableLevelAndNoSavedEffort_whenPresented_thenTheEffortRowIsHidden() {
        // given
        let node = candidate(model: "none")

        // when / then
        #expect(!WorkflowAgentEditorPresentation.showsEffort(effective(node), candidate: node))
    }

    @Test func givenASavedModelListingNoSelectableLevelAndASavedEffort_whenPresented_thenTheRowStaysWithTheUnavailableOption() {
        // given
        let node = candidate(model: "none", effort: "high")
        let controls = effective(node)

        // when
        let options = WorkflowAgentEditorPresentation.effortOptions(controls, saved: "high")

        // then
        #expect(WorkflowAgentEditorPresentation.showsEffort(controls, candidate: node))
        #expect(options == [
            .init(value: "", title: "Default"), .init(value: "high", title: "high — unavailable for this harness")
        ])
    }

    @Test func givenASavedEffortOutsideTheModelsLevels_whenPresented_thenItIsMarkedUnavailable() {
        // given
        let node = candidate(model: "subset", effort: "medium")

        // when
        let options = WorkflowAgentEditorPresentation.effortOptions(effective(node), saved: "medium")

        // then
        #expect(options.map(\.value) == ["", "low", "high", "medium"])
        #expect(options.last?.title == "medium — unavailable for this harness")
    }

    @Test func givenASavedModelWhoseLevelsAreDisjointFromTheHarness_whenPresented_thenNoLevelIsOffered() {
        // given
        let node = candidate(model: "disjoint")

        // when / then
        #expect(effective(node).effort == .unsupported)
        #expect(!WorkflowAgentEditorPresentation.showsEffort(effective(node), candidate: node))
    }

    // MARK: Unchanged cases

    @Test(arguments: [nil, "", "   ", "silent", "SUBSET", "sub", "unknown-model"] as [String?])
    func givenNoMatchOrNoLevels_whenPresented_thenTheHarnessControlsAreUnchanged(_ model: String?) {
        #expect(effective(candidate(model: model)) == harness)
    }

    @Test func givenTheSyntheticDefaultRow_whenTheNodeHasNoModel_thenItsLevelsAreNeverUsed() {
        // given: the Default row (id "") lists ["low"] in this fixture, which must not apply to an empty model
        let node = candidate(model: nil)

        // when / then
        #expect(effective(node).effort == harness.effort)
    }

    @Test func givenASavedModelWithSurroundingWhitespace_whenPresented_thenItStillMatches() {
        #expect(effective(candidate(model: " subset ")).effort == .levels(["low", "high"]))
    }

    @Test func givenNoLoadedSuggestions_whenPresented_thenTheHarnessControlsAreUnchanged() {
        // given
        let node = candidate(model: "none")

        // when
        let controls = WorkflowAgentEditorPresentation.effectiveControls(harness, candidate: node, choices: [])

        // then
        #expect(controls == harness)
    }

    @Test(arguments: [BackendControls.unavailable,
                      BackendControls(model: .supported, effort: .unsupported, turnCap: .supported)])
    func givenAHarnessWithoutLevels_whenTheModelListsLevels_thenTheHarnessStateIsKept(_ controls: BackendControls) {
        #expect(effective(candidate(model: "subset"), harness: controls) == controls)
    }
}

// MARK: - WorkflowModelEffortVMTests

/// Effort-only changes in reloaded suggestions must republish the choices the editors read.
@MainActor
@Suite struct WorkflowModelEffortVMTests {
    private final class Suggestions: @unchecked Sendable {
        private let lock = NSLock()
        private var options: [ModelOption]
        init(_ options: [ModelOption]) { self.options = options }
        var value: [ModelOption] {
            get { lock.withLock { options } }
            set { lock.withLock { options = newValue } }
        }
    }

    private func makeVM(
        suggestions: Suggestions, usage: CurrentValueSubject<AgentUsageSnapshot, Never>
    ) -> WorkflowVM {
        let useCase = MockWorkflowUseCase()
        useCase.stubBackendCatalog()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willProduce { _ in suggestions.value }
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(usage.eraseToAnyPublisher())
        given(useCase).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return WorkflowVM(
            useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler()
        )
    }

    @Test func givenSuggestionsWithEffortLevels_whenLoadedLate_thenTheChoicesCarryThemAndDefaultCarriesNone() async {
        // given
        let suggestions = Suggestions([ModelOption(value: "gpt-a", label: "GPT A", effortLevels: ["low"])])
        let vm = makeVM(suggestions: suggestions, usage: CurrentValueSubject(.init()))

        // when
        vm.loadModels("codex")
        await waitUntil { vm.modelChoices["codex"]?.count == 2 }

        // then
        #expect(vm.modelChoices["codex"] == [
            ModelChoiceModel(id: "", title: "Default"),
            ModelChoiceModel(id: "gpt-a", title: "GPT A", effortLevels: ["low"])
        ])
    }

    @Test func givenADefaultOnlyResult_whenLoadedAgainAfterOptionsExist_thenItIsRequestedAgain() async {
        // given
        let suggestions = Suggestions([])
        let vm = makeVM(suggestions: suggestions, usage: CurrentValueSubject(.init()))
        vm.loadModels("codex")
        await waitUntil { vm.modelChoices["codex"] != nil }
        #expect(vm.modelChoices["codex"] == [ModelChoiceModel(id: "", title: "Default")])

        // when
        suggestions.value = [ModelOption(value: "gpt-a", label: "GPT A", effortLevels: ["low"])]
        vm.loadModels("codex")
        await waitUntil { vm.modelChoices["codex"]?.count == 2 }

        // then
        #expect(vm.modelChoices["codex"]?.last == ModelChoiceModel(id: "gpt-a", title: "GPT A", effortLevels: ["low"]))
    }

    @Test func givenLoadedOptions_whenLoadedAgain_thenTheEngineIsNotAskedAgain() async {
        // given
        let suggestions = Suggestions([ModelOption(value: "gpt-a", label: "GPT A")])
        let vm = makeVM(suggestions: suggestions, usage: CurrentValueSubject(.init()))
        vm.loadModels("codex")
        await waitUntil { vm.modelChoices["codex"]?.count == 2 }

        // when
        suggestions.value = [ModelOption(value: "gpt-b", label: "GPT B")]
        vm.loadModels("codex")
        await Task.yield()

        // then
        #expect(vm.modelChoices["codex"]?.last?.id == "gpt-a")
    }

    @Test func givenLoadedChoices_whenReloadedWithOnlyDifferentEffortLevels_thenTheChoicesAreRepublished() async {
        // given
        let suggestions = Suggestions([ModelOption(value: "gpt-a", label: "GPT A", effortLevels: ["low", "high"])])
        let usage = CurrentValueSubject<AgentUsageSnapshot, Never>(.init())
        let vm = makeVM(suggestions: suggestions, usage: usage)
        vm.didAppear()
        defer { vm.didDisappear() }
        vm.loadModels("codex")
        await waitUntil { vm.modelChoices["codex"]?.last?.effortLevels == ["low", "high"] }

        // when
        suggestions.value = [ModelOption(value: "gpt-a", label: "GPT A", effortLevels: [])]
        usage.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "codex", model: "gpt-a"): 1]))
        await waitUntil { vm.modelChoices["codex"]?.last?.effortLevels == [] }

        // then
        #expect(vm.modelChoices["codex"]?.last == ModelChoiceModel(id: "gpt-a", title: "GPT A", effortLevels: []))
        #expect(vm.modelChoices["codex"]?.count == 2)
    }
}
