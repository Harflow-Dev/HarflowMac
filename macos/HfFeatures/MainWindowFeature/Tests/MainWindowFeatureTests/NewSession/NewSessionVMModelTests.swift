import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct NewSessionVMModelTests {

    private func makeSUT(catalog: BackendCatalog = .empty, models: [String: [ModelOption]] = [:], usage: AgentUsageSnapshot = .init(), appear: Bool = true) -> (
        sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting, catalogSubject: PassthroughSubject<BackendCatalog, Never>
    ) {
        let useCase = MockNewSessionUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockNewSessionRouting()
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).tasks.willReturn([])
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        given(useCase).models(for: .any).willProduce { models[$0] ?? [] }
        given(useCase).agentUsageSnapshot.willReturn(usage)
        given(useCase).agentUsagePublisher().willReturn(Just(usage).eraseToAnyPublisher())
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        if appear { sut.didAppear() }
        return (sut, useCase, routing, catalogSubject)
    }

    /// Starts a valid session and waits for the mocked run to complete.
    private func start(_ sut: NewSessionVM, _ useCase: MockNewSessionUseCase, _ routing: MockNewSessionRouting) async {
        given(routing).didStart(taskID: .any).willReturn()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any, runtime: .any).willReturn("id")
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do the thing")
        await waitUntil { sut.canStart }
        sut.didTapStart()
        await waitUntil { sut.isStarting == false }
    }

    private func catalog(_ entries: [(String, Bool?)]) -> BackendCatalog {
        BackendCatalog(entries: entries.map { BackendControlFixtures.entry($0.0, installed: $0.1) }, state: .available)
    }

    // MARK: - Model combo

    private let opusOption = ModelOption(value: "opus", label: "Opus")
    private let sonnetOption = ModelOption(value: "sonnet", label: "Sonnet")

    @Test func givenAnAgentWithKnownModels_whenTheSheetAppears_thenDefaultComesFirstThenTheModels() async {
        // given
        let (sut, _, _, _) = makeSUT(catalog: catalog([("claude", true)]), models: ["claude": [opusOption, sonnetOption]], appear: false)
        sut.didChangeBackend("claude")
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.modelChoices.count == 3 }
        #expect(sut.modelChoices == [
            ModelChoiceModel(id: "", title: "Default"), ModelChoiceModel(id: "opus", title: "Opus"), ModelChoiceModel(id: "sonnet", title: "Sonnet")
        ])
    }

    @Test func givenUsageAcrossBackends_whenTheSheetOpens_thenBackendsAndModelsAreRankedWithoutChangingLabels() async {
        // given
        let usage = AgentUsageSnapshot(counts: [
            AgentUsageIdentity(backend: "codex", model: "gpt-5"): 4,
            AgentUsageIdentity(backend: "claude", model: "opus"): 2
        ])
        let (sut, _, _, _) = makeSUT(
            catalog: catalog([("claude", true), ("codex", true)]),
            models: ["codex": [ModelOption(value: "gpt-5", label: "GPT 5"), ModelOption(value: "mini", label: "Mini")]],
            usage: usage
        )

        // when
        sut.didAppear()
        await waitUntil { sut.modelChoices.count == 3 }

        // then
        #expect(sut.agentOptions.map(\.id) == ["codex", "claude"])
        #expect(sut.modelChoices.map(\.id) == ["", "gpt-5", "mini"])
        #expect(sut.modelChoices.map(\.title) == ["Default", "GPT 5", "Mini"])
    }

    @Test(.timeLimit(.minutes(1))) func givenAnAgentWithNoKnownModels_whenTheSheetAppears_thenOnlyDefaultIsOffered() async {
        // given
        let (sut, useCase, _, _) = makeSUT(catalog: catalog([("claude", true)]), appear: false)

        // when
        // Synchronize on the actual invocation, not a deadline racing the shared MainActor queue.
        let invocation = AsyncStream<Bool>.makeStream()
        when(useCase).models(for: .any).perform { invocation.continuation.yield(true) }
        sut.didAppear()
        #expect(await invocation.stream.first(where: { @Sendable value in value }) == true)
        verify(useCase).models(for: .any).called(1)

        // then
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])
    }

    @Test func givenTheAgentChanges_whenTheNewListArrives_thenItReplacesTheOldOne() async {
        // given
        let (sut, _, _, _) = makeSUT(
            catalog: catalog([("claude", true), ("codex", true)]),
            models: ["claude": [opusOption], "codex": [ModelOption(value: "gpt-a", label: "GPT A")]]
        )
        sut.didAppear()
        await waitUntil { sut.modelChoices.count == 2 }

        // when
        sut.didChangeBackend("codex")

        // then
        await waitUntil { sut.modelChoices.map(\.id) == ["", "gpt-a"] }
        #expect(sut.modelChoices.map(\.id) == ["", "gpt-a"])
    }

    @Test func givenAModelWasTyped_whenTheAgentChanges_thenModelRemainsAndRequiresExplicitReview() {
        // given
        let (sut, useCase, _, _) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didChangeModel("opus")
        // when
        sut.didChangeBackend("codex")
        sut.didTapStart()
        // then
        #expect(sut.model == "opus")
        #expect(!sut.validationMessages.isEmpty)
        verify(useCase).run(.any, runtime: .any).called(0)
        sut.didChangeModel("opus")
        #expect(sut.validationMessages.isEmpty)
    }

    @Test func givenAModelWasTyped_whenTheSameAgentIsChosenAgain_thenTheModelIsKept() {
        // given
        let (sut, _, _, _) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didChangeModel("opus")

        // when
        sut.didChangeBackend("claude")

        // then
        #expect(sut.model == "opus")
    }

    @Test func givenTheSelectedAgentLeavesTheCatalog_whenReplaced_thenRequestedAgentAndModelRemain() async {
        // given
        let (sut, _, _, catalogSubject) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didAppear()
        sut.didChangeModel("opus")

        // when
        catalogSubject.send(catalog([("codex", true)]))

        // then
        await waitUntil { sut.agentNotFoundNote != nil }
        #expect(sut.backend == "claude")
        #expect(sut.model == "opus")
        #expect(!sut.canStart)
    }

    @Test func givenDefaultIsPicked_whenStarted_thenTheModelIsNil() async {
        // given
        let (sut, useCase, routing, _) = makeSUT()
        sut.didChangeModel("opus")

        // when
        sut.didChangeModel("")
        await start(sut, useCase, routing)

        // then
        verify(useCase).run(.matching { $0.model == nil }, runtime: .any).called(1)
    }

    @Test func givenASuggestionIsPicked_whenStarted_thenItsValueIsTheModel() async {
        // given
        let (sut, useCase, routing, _) = makeSUT(catalog: catalog([("claude", true)]), models: ["claude": [opusOption]])
        sut.didChangeBackend("claude")
        sut.didAppear()
        await waitUntil { sut.modelChoices.count == 2 }

        // when
        sut.didChangeModel(sut.modelChoices[1].id)
        await start(sut, useCase, routing)

        // then
        verify(useCase).run(.matching { $0.model == "opus" }, runtime: .any).called(1)
    }

    @Test func givenVibeWhoseModelSelectionIsNotReady_whenTheSheetAppears_thenNoModelListIsRequested() async {
        // given
        let (sut, useCase, _, _) = makeSUT(catalog: catalog([("vibe", true)]))

        // when
        sut.didAppear()

        // then — nothing to wait for: the engine says no model, so assert the call count stays zero.
        #expect(sut.showsModel == false)
        #expect(sut.modelUnavailableNote == "Model selection isn't available for this harness.")
        verify(useCase).models(for: .any).called(0)
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])
    }

    @Test func givenVibeWithModelSelectionReady_whenTheSheetAppears_thenModelIsShownAndSuggestionsAreRequested() async {
        // given
        let vibe = BackendControlFixtures.entry("vibe", facts: BackendControlFixtures.vibeReady)
        let (sut, useCase, _, _) = makeSUT(
            catalog: BackendCatalog(entries: [vibe], state: .available), models: ["vibe": [opusOption]]
        )

        // when
        await waitUntil { sut.modelChoices.count == 2 }

        // then
        #expect(sut.showsModel)
        #expect(sut.modelUnavailableNote == nil)
        verify(useCase).models(for: .value("vibe")).called(1)
    }

    @Test func givenAnAgentThatTakesAModel_whenTheNoteIsRead_thenItIsNil() {
        // given / when
        let (sut, _, _, _) = makeSUT(catalog: catalog([("claude", true)]))

        // then
        #expect(sut.showsModel)
        #expect(sut.modelUnavailableNote == nil)
    }

    @Test func givenFactsArriveAfterTheSheetOpened_whenTheModelBecomesSupported_thenSuggestionsLoadAndTheTypedModelStays() async {
        // given — the catalog is still loading, so the claude fallback has no model facts yet.
        let (sut, useCase, _, catalogSubject) = makeSUT(models: ["claude": [opusOption]])
        sut.didChangeBackend("claude")
        sut.didChangeModel("custom")
        #expect(sut.showsModel == false)
        verify(useCase).models(for: .any).called(0)

        // when
        catalogSubject.send(catalog([("claude", true)]))

        // then
        await waitUntil { sut.modelChoices.count == 2 }
        #expect(sut.showsModel)
        #expect(sut.model == "custom")
        #expect(sut.validationMessages.isEmpty)
    }

    @Test func givenVibeGateIsUnknownInAnAvailableCatalog_whenAModelIsTyped_thenNoWarningAndStartIsAllowed() async {
        // given — a failed identify() leaves the gate unknown; the engine decides at launch.
        let vibe = BackendControlFixtures.entry("vibe", facts: BackendControlFixtures.vibeUnknownGate)
        let (sut, useCase, routing, _) = makeSUT(catalog: BackendCatalog(entries: [vibe], state: .available))

        // when
        sut.didChangeModel("some-model")
        await start(sut, useCase, routing)

        // then
        #expect(sut.modelUnavailableNote == nil)
        #expect(sut.showsModel == false)
        verify(useCase).run(.matching { $0.model == "some-model" }, runtime: .any).called(1)
    }
}
