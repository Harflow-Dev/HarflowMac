import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

@MainActor
@Suite struct NewSessionVMModelTests {

    private func makeSUT(catalog: BackendCatalog = .empty, models: [String: [ModelOption]] = [:]) -> (
        sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting, catalogSubject: PassthroughSubject<BackendCatalog, Never>
    ) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).tasks.willReturn([])
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        given(useCase).models(for: .any).willProduce { models[$0] ?? [] }
        return (NewSessionVM(useCase: useCase, routing: routing), useCase, routing, catalogSubject)
    }

    /// Starts a valid session and waits for the mocked run to complete.
    private func start(_ sut: NewSessionVM, _ useCase: MockNewSessionUseCase, _ routing: MockNewSessionRouting) async {
        given(routing).didStart(taskID: .any).willReturn()
        given(useCase).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase).run(.any).willReturn("id")
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do the thing")
        sut.didTapStart()
        await waitUntil { sut.isStarting == false }
    }

    private func catalog(_ entries: [(String, Bool?)]) -> BackendCatalog {
        BackendCatalog(entries: entries.map { BackendCatalogEntry(backend: $0.0, installed: $0.1) }, state: .available)
    }

    // MARK: - Model combo

    private let opusOption = ModelOption(value: "opus", label: "Opus")
    private let sonnetOption = ModelOption(value: "sonnet", label: "Sonnet")

    @Test func givenAnAgentWithKnownModels_whenTheSheetAppears_thenDefaultComesFirstThenTheModels() async {
        // given
        let (sut, _, _, _) = makeSUT(models: ["claude": [opusOption, sonnetOption]])
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])

        // when
        sut.didAppear()

        // then
        await waitUntil { sut.modelChoices.count == 3 }
        #expect(sut.modelChoices == [
            ModelChoiceModel(id: "", title: "Default"), ModelChoiceModel(id: "opus", title: "Opus"), ModelChoiceModel(id: "sonnet", title: "Sonnet")
        ])
    }

    @Test(.timeLimit(.minutes(1))) func givenAnAgentWithNoKnownModels_whenTheSheetAppears_thenOnlyDefaultIsOffered() async {
        // given
        let (sut, useCase, _, _) = makeSUT()

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

    @Test func givenAModelWasTyped_whenTheAgentChanges_thenTheModelIsCleared() async {
        // given
        let (sut, useCase, routing, _) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didChangeModel("opus")

        // when
        sut.didChangeBackend("codex")
        await start(sut, useCase, routing)

        // then
        #expect(sut.model == "")
        verify(useCase).run(.matching { $0.backend == "codex" && $0.model == nil }).called(1)
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

    @Test func givenTheSelectedAgentLeavesTheCatalog_whenReplaced_thenTheModelIsCleared() async {
        // given
        let (sut, _, _, catalogSubject) = makeSUT(catalog: catalog([("claude", true), ("codex", true)]))
        sut.didAppear()
        sut.didChangeModel("opus")

        // when
        catalogSubject.send(catalog([("codex", true)]))

        // then
        await waitUntil { sut.backend == "codex" }
        #expect(sut.model == "")
    }

    @Test func givenDefaultIsPicked_whenStarted_thenTheModelIsNil() async {
        // given
        let (sut, useCase, routing, _) = makeSUT()
        sut.didChangeModel("opus")

        // when
        sut.didChangeModel("")
        await start(sut, useCase, routing)

        // then
        verify(useCase).run(.matching { $0.model == nil }).called(1)
    }

    @Test func givenASuggestionIsPicked_whenStarted_thenItsValueIsTheModel() async {
        // given
        let (sut, useCase, routing, _) = makeSUT(models: ["claude": [opusOption]])
        sut.didAppear()
        await waitUntil { sut.modelChoices.count == 2 }

        // when
        sut.didChangeModel(sut.modelChoices[1].id)
        await start(sut, useCase, routing)

        // then
        verify(useCase).run(.matching { $0.model == "opus" }).called(1)
    }

    @Test func givenVibeSelected_whenTheSheetAppears_thenNoModelListIsRequested() async {
        // given
        let (sut, useCase, _, _) = makeSUT(catalog: catalog([("vibe", true)]))

        // when
        sut.didAppear()

        // then — nothing to wait for: vibe never asks, so assert the call count stays zero.
        #expect(sut.showsModel == false)
        #expect(sut.modelUnavailableNote == "Vibe uses the model set in its own config (~/.vibe/config.toml).")
        verify(useCase).models(for: .any).called(0)
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])
    }

    @Test func givenAnAgentThatTakesAModel_whenTheNoteIsRead_thenItIsNil() {
        // given / when
        let (sut, _, _, _) = makeSUT()

        // then
        #expect(sut.showsModel)
        #expect(sut.modelUnavailableNote == nil)
    }
}
