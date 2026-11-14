import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

/// The effort control follows the chosen model: its own levels narrow the harness levels, and only
/// while the harness itself reports levels.
@MainActor
@Suite struct NewSessionVMModelEffortTests {
    private static let unavailableMessage = "The requested effort is unsupported by this harness."

    private final class Suggestions: @unchecked Sendable {
        private let lock = NSLock()
        private var options: [ModelOption]
        init(_ options: [ModelOption]) { self.options = options }
        var value: [ModelOption] {
            get { lock.withLock { options } }
            set { lock.withLock { options = newValue } }
        }
    }

    private struct Fixture {
        let sut: NewSessionVM
        let suggestions: Suggestions
        let catalogSubject: PassthroughSubject<BackendCatalog, Never>
        let usageSubject: CurrentValueSubject<AgentUsageSnapshot, Never>
    }

    private func makeSUT(backend: String = "claude", options: [ModelOption] = []) -> Fixture {
        let useCase = MockNewSessionUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        let usageSubject = CurrentValueSubject<AgentUsageSnapshot, Never>(.init())
        let suggestions = Suggestions(options)
        given(useCase).backendCatalog.willReturn(BackendCatalog(entries: [BackendControlFixtures.entry(backend)], state: .available))
        given(useCase).tasks.willReturn([])
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        given(useCase).models(for: .any).willProduce { _ in suggestions.value }
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(usageSubject.eraseToAnyPublisher())
        let sut = NewSessionVM(useCase: useCase, routing: MockNewSessionRouting())
        sut.didAppear()
        return Fixture(sut: sut, suggestions: suggestions, catalogSubject: catalogSubject, usageSubject: usageSubject)
    }

    private func loaded(_ options: [ModelOption]) async -> Fixture {
        let fixture = makeSUT(options: options)
        await waitUntil { fixture.sut.modelChoices.count == options.count + 1 }
        return fixture
    }

    private func catalog(_ state: BackendCatalogState, facts: BackendControlFacts? = nil) -> BackendCatalog {
        BackendCatalog(entries: facts.map { [BackendControlFixtures.entry("claude", facts: $0)] } ?? [], state: state)
    }

    private let harnessLevels = ["low", "medium", "high", "xhigh"]

    // MARK: - Matched model

    @Test func givenAModelListingASubsetOfLevels_whenChosen_thenOnlyThoseLevelsAreOfferedInHarnessOrder() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["high", "low"])])

        // when
        fixture.sut.didChangeModel("opus")

        // then
        #expect(fixture.sut.effortOptions == ["low", "high"])
        #expect(fixture.sut.showsEffort)
    }

    @Test func givenAModelListingASubset_whenARemovedLevelIsRequested_thenItBlocksStart() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "high"])])
        fixture.sut.didChangeModel("opus")

        // when
        fixture.sut.didChangeEffort("medium")

        // then
        #expect(fixture.sut.validationMessages == [Self.unavailableMessage])
        #expect(!fixture.sut.canStart)
    }

    @Test func givenAModelListingASubset_whenAListedLevelIsRequested_thenNoEffortMessageAppears() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "high"])])
        fixture.sut.didChangeModel("opus")

        // when
        fixture.sut.didChangeEffort("high")

        // then
        #expect(fixture.sut.validationMessages.isEmpty)
    }

    @Test func givenAModelWithNoSelectableLevels_whenChosen_thenNoLevelsAreOfferedAndASavedEffortBlocks() async {
        // given
        let fixture = await loaded([ModelOption(value: "mini", label: "Mini", effortLevels: [])])
        fixture.sut.didChangeEffort("high")
        #expect(fixture.sut.validationMessages.isEmpty)

        // when
        fixture.sut.didChangeModel("mini")

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
        #expect(!fixture.sut.showsEffort)
        #expect(fixture.sut.effort == "high")
        #expect(fixture.sut.validationMessages == [Self.unavailableMessage])
    }

    @Test func givenAModelWithNoSelectableLevelsAndNoEffort_whenChosen_thenNothingBlocksStart() async {
        // given
        let fixture = await loaded([ModelOption(value: "mini", label: "Mini", effortLevels: [])])

        // when
        fixture.sut.didChangeModel("mini")

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
        #expect(fixture.sut.validationMessages.isEmpty)
    }

    @Test func givenAModelThatSaysNothingAboutLevels_whenChosen_thenTheHarnessLevelsStay() async {
        // given
        let fixture = await loaded([ModelOption(value: "sonnet", label: "Sonnet", effortLevels: nil)])

        // when
        fixture.sut.didChangeModel("sonnet")

        // then
        #expect(fixture.sut.effortOptions == harnessLevels)
    }

    @Test func givenAModelListingLevelsTheHarnessLacks_whenChosen_thenItNeverWidensTheHarness() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["minimal", "low", "ultra"])])

        // when
        fixture.sut.didChangeModel("opus")

        // then
        #expect(fixture.sut.effortOptions == ["low"])
    }

    @Test func givenAModelListingOnlyOtherLevels_whenChosen_thenNoLevelIsOffered() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["minimal"])])

        // when
        fixture.sut.didChangeModel("opus")

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
    }

    // MARK: - Unmatched model

    @Test(arguments: ["", "   ", "Opus", "opu", "opus-4", "other"])
    func givenTextThatIsNotAnExactSuggestion_whenTyped_thenTheHarnessLevelsStay(_ text: String) async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: [])])

        // when
        fixture.sut.didChangeModel(text)

        // then
        #expect(fixture.sut.effortOptions == harnessLevels)
    }

    @Test func givenASuggestionWithSurroundingWhitespace_whenTyped_thenItStillMatches() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: [])])

        // when
        fixture.sut.didChangeModel("  opus\n")

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
    }

    // MARK: - Re-evaluation

    @Test func givenAChangingModel_whenItChanges_thenEffortIsReevaluatedEachTime() async {
        // given
        let fixture = await loaded([
            ModelOption(value: "a", label: "A", effortLevels: ["low"]),
            ModelOption(value: "b", label: "B", effortLevels: nil),
            ModelOption(value: "c", label: "C", effortLevels: [])
        ])

        // when / then
        fixture.sut.didChangeModel("a")
        #expect(fixture.sut.effortOptions == ["low"])
        fixture.sut.didChangeModel("b")
        #expect(fixture.sut.effortOptions == harnessLevels)
        fixture.sut.didChangeModel("c")
        #expect(fixture.sut.effortOptions.isEmpty)
        fixture.sut.didChangeModel("")
        #expect(fixture.sut.effortOptions == harnessLevels)
    }

    @Test func givenAModelTypedBeforeSuggestionsArrive_whenAnEmptyLevelListArrives_thenASavedEffortIsThenBlocked() async {
        // given
        let fixture = makeSUT(options: [])
        fixture.sut.didChangeModel("opus")
        fixture.sut.didChangeEffort("high")
        #expect(fixture.sut.effortOptions == harnessLevels)
        #expect(fixture.sut.validationMessages.isEmpty)

        // when
        fixture.suggestions.value = [ModelOption(value: "opus", label: "Opus", effortLevels: [])]
        fixture.usageSubject.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: "opus"): 1]))
        await waitUntil { fixture.sut.modelChoices.count == 2 }

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
        #expect(fixture.sut.validationMessages == [Self.unavailableMessage])
    }

    @Test func givenAnEffortOnlyChangeInReloadedSuggestions_whenTheyArrive_thenTheNewLevelsApply() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "high"])])
        fixture.sut.didChangeModel("opus")
        #expect(fixture.sut.effortOptions == ["low", "high"])

        // when
        fixture.suggestions.value = [ModelOption(value: "opus", label: "Opus", effortLevels: ["medium"])]
        fixture.usageSubject.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: "opus"): 1]))
        await waitUntil { fixture.sut.effortOptions == ["medium"] }

        // then
        #expect(fixture.sut.effortOptions == ["medium"])
    }

    // MARK: - Harness facts always win

    @Test func givenCachedSuggestions_whenTheHarnessLevelsChange_thenTheResultFollowsTheCurrentHarness() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "medium"])])
        fixture.sut.didChangeModel("opus")
        #expect(fixture.sut.effortOptions == ["low", "medium"])
        let narrower = BackendControlFacts(
            supportsModelSelection: true, supportsTurnCap: true,
            effort: .init(acceptsParameter: true, levels: ["medium", "high"]), modelSelection: .notDeclared
        )

        // when
        fixture.catalogSubject.send(catalog(.available, facts: narrower))
        await waitUntil { fixture.sut.effortOptions == ["medium"] }

        // then
        #expect(fixture.sut.effortOptions == ["medium"])
    }

    @Test func givenCachedSuggestions_whenTheHarnessStopsReportingEffort_thenTheModelLevelsDoNotReviveIt() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "medium"])])
        fixture.sut.didChangeModel("opus")
        fixture.sut.didChangeEffort("low")
        let none = BackendControlFacts(
            supportsModelSelection: true, supportsTurnCap: true,
            effort: .init(acceptsParameter: false, levels: []), modelSelection: .notDeclared
        )

        // when
        fixture.catalogSubject.send(catalog(.available, facts: none))
        await waitUntil { fixture.sut.effortOptions.isEmpty }

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
        #expect(fixture.sut.validationMessages == [Self.unavailableMessage])
    }

    @Test func givenCachedSuggestions_whenTheCatalogDegrades_thenEffortIsUnknownNotFromTheModel() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "medium"])])
        fixture.sut.didChangeModel("opus")

        // when
        fixture.catalogSubject.send(catalog(.degraded))
        await waitUntil { fixture.sut.controls == .unavailable }

        // then
        #expect(fixture.sut.effortOptions.isEmpty)
        #expect(fixture.sut.controls == .unavailable)
    }

    @Test func givenCachedSuggestions_whenTheHarnessDisappearsFromTheCatalog_thenEffortIsNotFromTheModel() async {
        // given
        let fixture = await loaded([ModelOption(value: "opus", label: "Opus", effortLevels: ["low", "medium"])])
        fixture.sut.didChangeModel("opus")

        // when
        fixture.catalogSubject.send(BackendCatalog(entries: [BackendControlFixtures.entry("codex")], state: .available))
        await waitUntil { fixture.sut.controls == .unavailable }

        // then
        #expect(fixture.sut.controls == .unavailable)
        #expect(fixture.sut.effortOptions.isEmpty)
    }
}
