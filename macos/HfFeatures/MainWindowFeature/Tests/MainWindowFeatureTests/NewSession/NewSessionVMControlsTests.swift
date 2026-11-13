import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

/// Run-option controls follow the engine-reported facts of the catalog, never the backend name.
@MainActor
@Suite struct NewSessionVMControlsTests {
    private static let loadingMessage = "Harness options can't be checked until the harness list is available."

    private func makeSUT(catalog: BackendCatalog) -> (
        sut: NewSessionVM, useCase: MockNewSessionUseCase, catalogSubject: PassthroughSubject<BackendCatalog, Never>
    ) {
        let useCase = MockNewSessionUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let catalogSubject = PassthroughSubject<BackendCatalog, Never>()
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).tasks.willReturn([])
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject.eraseToAnyPublisher())
        given(useCase).models(for: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let sut = NewSessionVM(useCase: useCase, routing: MockNewSessionRouting())
        sut.didAppear()
        return (sut, useCase, catalogSubject)
    }

    private func catalog(_ entries: [BackendCatalogEntry], state: BackendCatalogState = .available) -> BackendCatalog {
        BackendCatalog(entries: entries, state: state)
    }

    private func all(_ names: String...) -> BackendCatalog {
        catalog(names.map { BackendControlFixtures.entry($0) })
    }

    // MARK: - Per harness facts

    @Test func givenClaudeAndCodex_whenSelected_thenTheyOfferFourEffortLevels() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("claude", "codex"))
        // when / then
        for name in ["claude", "codex"] {
            sut.didChangeBackend(name)
            #expect(sut.effortOptions == ["low", "medium", "high", "xhigh"], "\(name)")
            #expect(sut.showsEffort)
        }
    }

    @Test func givenCursor_whenSelected_thenThereIsNoEffortAndNoTurnLimitButAModel() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("cursor", "claude"))
        // when
        sut.didChangeBackend("cursor")
        // then
        #expect(sut.effortOptions.isEmpty)
        #expect(!sut.showsEffort)
        #expect(sut.showsModel)
        #expect(!sut.showsTurnLimit)
    }

    @Test func givenAntigravity_whenSelected_thenOnlyThreeLevelsAreOffered() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("antigravity", "claude"))
        // when
        sut.didChangeBackend("antigravity")
        // then
        #expect(sut.effortOptions == ["low", "medium", "high"])
    }

    @Test func givenTurnCapFacts_whenBackendsAreSelected_thenOnlyClaudeAndVibeShowTheTurnLimit() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("claude", "vibe", "codex", "opencode", "cursor", "antigravity"))
        // when / then
        for (name, expected) in [("claude", true), ("vibe", true), ("codex", false), ("opencode", false), ("cursor", false), ("antigravity", false)] {
            sut.didChangeBackend(name)
            #expect(sut.showsTurnLimit == expected, "\(name)")
        }
    }

    @Test func givenVibeGateAbsentOrNotReady_whenSelected_thenNoModelAndNoSuggestionsRequested() async {
        // given — an unavailable_reason row reads as an unknown gate; the 3.0.2 row reads as not ready.
        let unknown = BackendControlFixtures.entry("vibe", facts: BackendControlFixtures.vibeUnknownGate)
        let notReady = BackendControlFixtures.entry("vibe")
        for entry in [unknown, notReady] {
            let (sut, useCase, _) = makeSUT(catalog: catalog([entry]))
            // when
            sut.didAppear()
            // then
            #expect(!sut.showsModel)
            verify(useCase).models(for: .any).called(0)
        }
    }

    @Test func givenAnEffortOutsideTheReportedLevels_whenChosen_thenItKeepsItsUnsupportedMessage() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("antigravity"))
        // when
        sut.didChangeEffort("xhigh")
        // then
        #expect(sut.effort == "xhigh")
        #expect(sut.validationMessages == ["The requested effort is unsupported by this harness."])
        #expect(!sut.canStart)
    }

    @Test func givenAnEffortOnAHarnessWithNone_whenChosen_thenItIsUnsupportedAndBlocks() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("cursor"))
        // when
        sut.didChangeEffort("high")
        // then
        #expect(sut.validationMessages == ["The requested effort is unsupported by this harness."])
    }

    // MARK: - Loading and degraded catalogs

    @Test func givenALoadingCatalog_whenOnlyDefaultsAreSet_thenNoOptionsAndNoMessage() {
        // given / when
        let (sut, _, _) = makeSUT(catalog: .empty)
        // then
        #expect(sut.effortOptions.isEmpty)
        #expect(!sut.showsModel)
        #expect(!sut.showsTurnLimit)
        #expect(sut.modelUnavailableNote == nil)
        #expect(sut.validationMessages.isEmpty)
    }

    @Test func givenALoadingCatalog_whenSeveralNonDefaultValuesAreSet_thenOneMessageAppearsOnce() {
        // given
        let (sut, _, _) = makeSUT(catalog: .empty)
        // when
        sut.didChangeModel("opus")
        sut.didChangeEffort("high")
        sut.didChangeTurnLimit("12")
        // then
        #expect(sut.validationMessages == [Self.loadingMessage])
        #expect(sut.turnLimitError == nil)
        #expect(!sut.canStart)
    }

    @Test func givenADegradedCatalogAndABadTurnLimit_whenRead_thenOnlyTheNumberFormatErrorRemainsBesideTheSingleMessage() {
        // given
        let degraded = catalog([BackendCatalogEntry(backend: "claude", installed: nil)], state: .degraded)
        let (sut, _, _) = makeSUT(catalog: degraded)
        sut.didChangeBackend("claude")
        // when
        sut.didChangeTurnLimit("abc")
        // then
        #expect(sut.turnLimitError == "Enter a whole number above 0, or leave it empty for the default.")
        #expect(sut.validationMessages.filter { $0 == Self.loadingMessage }.count == 1)
        #expect(!sut.validationMessages.contains("The requested turn limit is unsupported by this harness."))
    }

    @Test func givenAnAvailableCatalogMissingAFact_whenValuesAreSet_thenNoPerControlWarningAppears() {
        // given — the entry reports nothing: every control is unknown, but the catalog is available.
        let bare = BackendCatalogEntry(backend: "claude", installed: true)
        let (sut, _, _) = makeSUT(catalog: catalog([bare]))
        // when
        sut.didChangeEffort("high")
        sut.didChangeTurnLimit("5")
        // then
        #expect(sut.validationMessages.isEmpty)
        #expect(sut.turnLimitError == nil)
    }

    // MARK: - Facts arriving late and backend changes

    @Test func givenAnEffortRetainedWhileLoading_whenFactsArrive_thenItIsRevalidatedNotCleared() async {
        // given
        let (sut, _, subject) = makeSUT(catalog: .empty)
        sut.didChangeBackend("antigravity")
        sut.didChangeEffort("xhigh")
        #expect(sut.validationMessages == [Self.loadingMessage])
        // when
        subject.send(all("antigravity"))
        // then
        await waitUntil { sut.validationMessages == ["The requested effort is unsupported by this harness."] }
        #expect(sut.effort == "xhigh")
    }

    @Test func givenValuesSetForClaude_whenBackendChangesToCursor_thenValuesStayAndMessagesShow() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("claude", "cursor"))
        sut.didChangeBackend("claude")
        sut.didChangeEffort("high")
        sut.didChangeTurnLimit("9")
        sut.didChangeModel("opus")
        // when
        sut.didChangeBackend("cursor")
        // then
        #expect(sut.effort == "high" && sut.turnLimit == "9" && sut.model == "opus")
        #expect(sut.validationMessages.contains("The requested effort is unsupported by this harness."))
        #expect(sut.turnLimitError == "The requested turn limit is unsupported by this harness.")
        #expect(sut.validationMessages.contains("Review and select the model for this harness."))
    }

    @Test func givenVibeNotReady_whenAModelIsTyped_thenTheUnsupportedMessageBlocksStart() {
        // given
        let (sut, _, _) = makeSUT(catalog: all("vibe"))
        // when
        sut.didChangeModel("m")
        // then
        #expect(sut.validationMessages == ["This harness does not accept a model option. Choose Default explicitly."])
        #expect(!sut.canStart)
    }
}
