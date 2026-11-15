import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

/// A use case whose listing reads suspend until the test answers them, in the order they were requested.
@MainActor
private final class ControlledListingUseCase: NewSessionUseCase {
    struct Request {
        let backend: String
        let isRefresh: Bool
        let continuation: CheckedContinuation<ModelListing, Never>
    }

    let base = MockNewSessionUseCase()
    /// Held here because the view model keeps its routing weakly.
    let routing = MockNewSessionRouting()
    private(set) var requests: [Request] = []
    let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
    let usageSubject: CurrentValueSubject<AgentUsageSnapshot, Never>
    private let catalog: BackendCatalog
    private let usage: AgentUsageSnapshot

    init(catalog: BackendCatalog, usage: AgentUsageSnapshot = .init()) {
        self.catalog = catalog
        self.usage = usage
        self.usageSubject = CurrentValueSubject(usage)
        given(base).qualificationSession().willReturn(QualificationFixture.readySession())
        given(base).tasks.willReturn([])
    }

    func qualificationSession() -> QualificationSession { base.qualificationSession() }
    func resolvedRepoPath(_ input: String) -> String? { base.resolvedRepoPath(input) }
    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String { try await base.run(request, runtime: runtime) }
    var tasks: [TaskInfo] { [] }
    var agentUsageSnapshot: AgentUsageSnapshot { usageSubject.value }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { usageSubject.eraseToAnyPublisher() }
    var backendCatalog: BackendCatalog { catalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { catalogSubject.eraseToAnyPublisher() }

    func modelListing(for backend: String) async -> ModelListing {
        await withCheckedContinuation { requests.append(Request(backend: backend, isRefresh: false, continuation: $0)) }
    }

    func refreshModelListing(for backend: String) async -> ModelListing {
        await withCheckedContinuation { requests.append(Request(backend: backend, isRefresh: true, continuation: $0)) }
    }

    func answer(_ index: Int, _ listing: ModelListing) { requests[index].continuation.resume(returning: listing) }
}

@MainActor
@Suite struct NewSessionVMModelListingTests {

    private let opus = ModelOption(value: "opus", label: "Opus")
    private let auto = ModelOption(value: "auto", label: "Auto", isDefault: true)

    private func catalog(_ names: String...) -> BackendCatalog {
        BackendCatalog(entries: names.map { BackendControlFixtures.entry($0) }, state: .available)
    }

    private func makeSUT(
        _ catalog: BackendCatalog, usage: AgentUsageSnapshot = .init(), appear: Bool = true
    ) -> (sut: NewSessionVM, useCase: ControlledListingUseCase) {
        let useCase = ControlledListingUseCase(catalog: catalog, usage: usage)
        let sut = NewSessionVM(useCase: useCase, routing: useCase.routing)
        if appear { sut.didAppear() }
        return (sut, useCase)
    }

    private func available(_ options: [ModelOption] = [], truncated: Bool = false, dropped: Int = 0) -> ModelListing {
        ModelListing(state: .available, options: options, truncated: truncated, droppedCount: dropped)
    }

    private let unavailable = ModelListing(state: .unavailable(.timeout))

    private func settle() async {
        for _ in 0 ..< 20 { await Task.yield() }
    }

    // MARK: - Loading

    @Test func givenASheetThatAppears_whenTheListingIsPending_thenLoadingShowsUntilItIsAnswered() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }

        // then
        #expect(sut.modelListingPhase == .loading)
        #expect(sut.modelNote?.text == "Loading suggested models… You can still type a model name.")

        // when
        useCase.answer(0, available([opus]))

        // then
        await waitUntil { sut.modelListingPhase == .loaded(available([opus])) }
        #expect(sut.modelNote == nil)
        #expect(sut.modelChoices.map(\.id) == ["", "opus"])
    }

    @Test func givenAHarnessThatTakesNoModel_whenTheSheetAppears_thenNoListingIsReadAndThePhaseIsIdle() async {
        // given / when
        let (sut, useCase) = makeSUT(catalog("vibe"))
        await settle()

        // then
        #expect(sut.modelListingPhase == .idle)
        #expect(useCase.requests.isEmpty)
        #expect(sut.modelNote?.text == "Model selection isn't available for this harness.")
    }

    @Test func givenAnUnavailableListing_whenItLoads_thenTheNoteOffersRetry() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }

        // when
        useCase.answer(0, unavailable)

        // then
        await waitUntil { sut.modelNote?.showsRetry == true }
        #expect(sut.modelNote?.text == "Suggested models aren't available. Claude took too long to list its models. You can still type a model name.")
        #expect(sut.modelChoices == [ModelChoiceModel(id: "", title: "Default")])
    }

    @Test func givenAnAnswerWithADefaultRow_whenItLoads_thenTheChoiceIsTagged() async {
        // given
        let (sut, useCase) = makeSUT(catalog("cursor"))
        await waitUntil { useCase.requests.count == 1 }

        // when
        useCase.answer(0, available([auto, opus]))

        // then
        await waitUntil { sut.modelChoices.count == 3 }
        #expect(sut.modelChoices.map(\.isDefault) == [false, true, false])
    }

    // MARK: - Retry

    @Test func givenAnUnavailableListing_whenRetryIsTapped_thenItGoesThroughLoadingAndReadsAgain() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, unavailable)
        await waitUntil { sut.modelNote?.showsRetry == true }

        // when
        sut.didTapRetryModels()

        // then
        #expect(sut.modelListingPhase == .loading)
        await waitUntil { useCase.requests.count == 2 }
        #expect(useCase.requests[1].isRefresh)
        useCase.answer(1, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }
        #expect(sut.modelListingPhase == .loaded(available([opus])))
    }

    @Test(arguments: ["available", "loading"])
    func givenRetryIsNotOffered_whenItIsTapped_thenNothingIsRead(_ situation: String) async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        if situation == "available" {
            useCase.answer(0, available([opus]))
            await waitUntil { sut.modelChoices.count == 2 }
        }

        // when
        sut.didTapRetryModels()
        await settle()

        // then
        #expect(useCase.requests.count == 1)
    }

    @Test func givenLockedOptions_whenRetryIsTapped_thenNothingIsRead() async {
        // given — a started task locks the composer.
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, unavailable)
        await waitUntil { sut.modelNote?.showsRetry == true }
        given(useCase.base).resolvedRepoPath(.any).willReturn("/tmp/repo")
        given(useCase.base).run(.any, runtime: .any).willReturn("id")
        given(useCase.routing).didStart(taskID: .any).willReturn()
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("go")
        await waitUntil { sut.canStart }
        sut.didTapStart()
        await waitUntil { sut.optionsLocked && !sut.isStarting }

        // when
        sut.didTapRetryModels()
        await settle()

        // then
        #expect(useCase.requests.count == 1)
    }

    @Test func givenARetryInFlight_whenTheHarnessChanges_thenItsAnswerIsDropped() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude", "codex"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, unavailable)
        await waitUntil { sut.modelNote?.showsRetry == true }
        sut.didTapRetryModels()
        await waitUntil { useCase.requests.count == 2 }

        // when
        sut.didChangeBackend("codex")
        await waitUntil { useCase.requests.count == 3 }
        useCase.answer(1, available([opus]))
        await settle()

        // then
        #expect(sut.backend == "codex")
        #expect(sut.modelListingPhase == .loading)
        #expect(sut.modelOptions.isEmpty)
    }

    @Test func givenARetryInFlight_whenTheModelControlTurnsUnsupported_thenItsAnswerIsDropped() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, unavailable)
        await waitUntil { sut.modelNote?.showsRetry == true }
        sut.didTapRetryModels()
        await waitUntil { useCase.requests.count == 2 }

        // when
        let noModel = BackendControlFixtures.entry("claude", facts: BackendControlFixtures.vibeNotReady)
        useCase.catalogSubject.send(BackendCatalog(entries: [noModel], state: .available))
        await waitUntil { sut.modelListingPhase == .idle }
        useCase.answer(1, available([opus]))
        await settle()

        // then
        #expect(sut.modelListingPhase == .idle)
        #expect(sut.modelOptions.isEmpty)
    }

    // MARK: - Supersession

    @Test func givenTwoLoadsForTheSameHarness_whenTheOlderAnswersLast_thenTheNewerAnswerStands() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        sut.didAppear()
        await waitUntil { useCase.requests.count == 2 }

        // when
        useCase.answer(1, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }
        useCase.answer(0, available([auto, opus]))
        await settle()

        // then
        #expect(sut.modelChoices.map(\.id) == ["", "opus"])
    }

    @Test func givenAHarnessSwitchedAwayAndBack_whenTheFirstAnswerArrivesLate_thenItIsDropped() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude", "codex"))
        await waitUntil { useCase.requests.count == 1 }
        sut.didChangeBackend("codex")
        await waitUntil { useCase.requests.count == 2 }
        sut.didChangeBackend("claude")
        await waitUntil { useCase.requests.count == 3 }

        // when
        useCase.answer(0, available([auto]))
        await settle()

        // then
        #expect(sut.modelListingPhase == .loading)
        #expect(sut.modelOptions.isEmpty)

        // when
        useCase.answer(2, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }

        // then
        #expect(sut.modelChoices.map(\.id) == ["", "opus"])
    }

    @Test func givenTheSheetDisappearsDuringALoad_whenTheAnswerArrives_thenItIsDropped() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }

        // when
        sut.didDisappear()
        useCase.answer(0, available([opus]))
        await settle()

        // then
        #expect(sut.modelListingPhase == .loading)
        #expect(sut.modelOptions.isEmpty)
    }

    // MARK: - Retained listings

    @Test func givenAUsageTick_whenTheListingIsLoaded_thenItReRanksWithoutShowingLoading() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        let sonnet = ModelOption(value: "sonnet", label: "Sonnet")
        useCase.answer(0, available([opus, sonnet]))
        await waitUntil { sut.modelChoices.count == 3 }

        // when
        useCase.usageSubject.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: "sonnet"): 3]))
        await waitUntil { sut.modelChoices.map(\.id) == ["", "sonnet", "opus"] }

        // then
        #expect(sut.modelListingPhase == .loaded(available([opus, sonnet])))
        #expect(useCase.requests.count == 1)
    }

    @Test func givenAHarnessWasLoaded_whenSwitchingBackToIt_thenItsListingAndOptionsAreRestoredAtOnce() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude", "codex"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }
        sut.didChangeBackend("codex")
        await waitUntil { useCase.requests.count == 2 }
        useCase.answer(1, ModelListing(state: .notInstalled))
        await waitUntil { sut.modelListingPhase == .loaded(ModelListing(state: .notInstalled)) }

        // when
        sut.didChangeBackend("claude")

        // then — synchronously, before the background read answers
        #expect(sut.modelListingPhase == .loaded(available([opus])))
        #expect(sut.modelChoices.map(\.id) == ["", "opus"])
        #expect(sut.modelNote == nil)
        await waitUntil { useCase.requests.count == 3 }
    }

    @Test func givenARetainedListing_whenTheSheetReappears_thenNoLoadingFlashesWhileItRefreshes() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }

        // when
        sut.didDisappear()
        sut.didAppear()

        // then
        #expect(sut.modelListingPhase == .loaded(available([opus])))
        await waitUntil { useCase.requests.count == 2 }
    }

    // MARK: - Start gating

    /// A startable baseline: qualified, with repository, message and backend set.
    private func makeStartable(_ useCase: ControlledListingUseCase, _ sut: NewSessionVM) async {
        sut.didChangeRepo("/tmp/repo")
        sut.didChangeMessage("do it")
        await waitUntil { sut.canStart }
    }

    /// `didAppear` re-prepares qualification, so a startable harness is awaited, not sampled.
    private func expectStartable(_ sut: NewSessionVM, _ startable: Bool) async {
        if startable { await waitUntil { sut.canStart } }
        #expect(sut.canStart == startable)
    }

    @Test(arguments: [("low", true), ("high", false)])
    func givenAModelWithRestrictedEffort_whenTheListingReloadsAndTicks_thenStartGatingNeverChanges(_ effort: String, _ startable: Bool) async {
        // given
        let restricted = ModelOption(value: "opus", label: "Opus", effortLevels: ["low"])
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, available([restricted]))
        await waitUntil { sut.modelChoices.count == 2 }
        sut.didChangeModel("opus")
        sut.didChangeEffort(effort)
        if startable {
            await makeStartable(useCase, sut)
        } else {
            sut.didChangeRepo("/tmp/repo")
            sut.didChangeMessage("do it")
        }
        let messages = sut.validationMessages
        #expect(sut.canStart == startable)
        #expect(messages.isEmpty == startable)

        // when — a reload in flight
        sut.didAppear()
        await waitUntil { useCase.requests.count == 2 }

        // then
        #expect(sut.validationMessages == messages)
        await expectStartable(sut, startable)

        // when — a usage tick
        useCase.usageSubject.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: "opus"): 1]))
        await settle()

        // then
        #expect(sut.validationMessages == messages)
        await expectStartable(sut, startable)

        // when — the answer lands
        useCase.answer(1, available([restricted]))
        await settle()

        // then
        #expect(sut.validationMessages == messages)
        await expectStartable(sut, startable)
    }

    @Test func givenAnUnavailableListing_whenRetryIsTappedAndAnswered_thenStartStaysAvailableThroughout() async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, unavailable)
        await waitUntil { sut.modelNote?.showsRetry == true }
        sut.didChangeModel("opus")
        await makeStartable(useCase, sut)
        #expect(sut.canStart)

        // when
        sut.didTapRetryModels()
        await waitUntil { useCase.requests.count == 2 }

        // then
        #expect(sut.modelListingPhase == .loading)
        #expect(sut.canStart)
        #expect(sut.validationMessages.isEmpty)

        // when
        useCase.answer(1, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }

        // then
        #expect(sut.canStart)
        #expect(sut.validationMessages.isEmpty)
    }

    @Test(arguments: [
        ModelListingState.available, .notInstalled, .unsupported, .unavailable(.timeout), .unrecognized("x"), .unreadable
    ])
    func givenAnyListingState_whenItLoads_thenStartStaysAvailable(_ state: ModelListingState) async {
        // given
        let (sut, useCase) = makeSUT(catalog("claude"))
        await makeStartable(useCase, sut)
        #expect(sut.canStart)
        let messages = sut.validationMessages
        await waitUntil { useCase.requests.count == 1 }

        // when
        useCase.answer(0, ModelListing(state: state))
        await waitUntil { sut.modelListingPhase != .loading }

        // then
        #expect(sut.validationMessages == messages)
        #expect(sut.canStart)
    }

    // MARK: - Stale re-rank

    @Test func givenAHeldReRank_whenTheNewerListingAppliesFirst_thenTheStaleReRankDoesNotOverwriteIt() async {
        // given — a loaded listing and a background read in flight
        let (sut, useCase) = makeSUT(catalog("claude"))
        await waitUntil { useCase.requests.count == 1 }
        useCase.answer(0, available([opus]))
        await waitUntil { sut.modelChoices.count == 2 }
        let (entered, enteredSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        sut.rerankCompletionGate = {
            enteredSignal.yield(())
            for await _ in release { return }
        }
        sut.didAppear()
        await waitUntil { useCase.requests.count == 2 }

        // when — a usage tick starts a re-rank of the old listing and it is held before applying
        useCase.usageSubject.send(AgentUsageSnapshot(counts: [AgentUsageIdentity(backend: "claude", model: "opus"): 1]))
        for await _ in entered { break }
        // and the newer listing applies
        useCase.answer(1, available([auto]))
        await waitUntil { sut.modelListingPhase == .loaded(available([auto])) }
        #expect(sut.modelChoices.map(\.id) == ["", "auto"])

        // when — the stale ranking is released and awaited
        releaseSignal.yield(())
        await settle()

        // then
        #expect(sut.modelListingPhase == .loaded(available([auto])))
        #expect(sut.modelOptions == [auto])
        #expect(sut.modelChoices.map(\.id) == ["", "auto"])
        #expect(sut.modelNote == nil)
        sut.didDisappear()
        sut.didAppear()
        #expect(sut.modelChoices.map(\.id) == ["", "auto"], "The retained listing must be the newer one.")
    }
}
