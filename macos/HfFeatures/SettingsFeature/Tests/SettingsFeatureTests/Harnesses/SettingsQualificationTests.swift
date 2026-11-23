import HfRepository
import HfTestUtilities
import Mockable
import MonitorCore
@testable import SettingsFeature
import Testing

@MainActor
struct SettingsQualificationTests {
    private func make(_ fixture: QualificationFixture, session: QualificationSession? = nil) -> HarnessesVM {
        let useCase = MockHarnessesUseCase()
        HarnessesVMTests.stubRuntime(useCase)
        given(useCase).status().willReturn(.failure(.launchFailed(tool: "fixture", detail: "Fixture registration status unavailable")))
        given(useCase).qualificationBackends().willReturn([QualificationBackend(backend: "claude", installed: true)])
        given(useCase).qualificationSession().willReturn(session ?? QualificationSession(repository: fixture))
        return HarnessesVM(useCase: useCase)
    }

    @Test func givenCachedFeatureEvidence_whenSettingsOpens_thenInspectWithoutProviderCheck() async {
        // given
        let fixture = QualificationFixture()
        let vm = make(fixture)
        // when
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .ready }
        // then
        #expect(fixture.checks == 0)
        #expect(vm.qualificationCards.first?.model.features.map(\.id) == ["write"])
        vm.didDisappear()
    }

    @Test func givenFailedFeature_whenExplicitlyRetried_thenOnlyQualificationCheckRuns() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let vm = make(fixture)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        // when
        fixture.setReady(true)
        vm.didTapQualification("claude:settings/claude")
        await waitUntil { vm.qualificationCards.first?.model.state == .ready }
        // then
        #expect(fixture.checks == 1)
        vm.didDisappear()
    }

    @Test func givenUnsupportedEngine_whenSettingsOpens_thenUnsupportedIsDistinctFromRegistrationStatus() async {
        // given
        let fixture = QualificationFixture(error: .unsupportedCommand(tool: "harflow-ctl", command: "qualification", detail: "fixture"))
        let vm = make(fixture)
        // when
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .unsupported }
        // then
        #expect(fixture.checks == 0)
        #expect(vm.qualificationCards.first?.model.state.title == "Unsupported runtime")
        #expect(vm.qualificationCards.first?.model.message
            == "Harness qualification is unavailable in this Harflow runtime. A supporting managed runtime is required.")
        #expect(vm.qualificationCards.first?.model.actionTitle == nil)
        vm.didDisappear()
    }

    @Test func givenTwoBackendReadFailures_whenRetryingSecondCard_thenOnlyItsOwnHarnessIsChecked() async {
        // given
        let first = CachedFailureQualificationFixture()
        let second = CachedFailureQualificationFixture()
        let queue = QualificationSessionQueue([QualificationSession(repository: first), QualificationSession(repository: second)])
        let useCase = MockHarnessesUseCase()
        HarnessesVMTests.stubRuntime(useCase)
        given(useCase).status().willReturn(.failure(.launchFailed(tool: "fixture", detail: "Fixture registration status")))
        given(useCase).qualificationBackends().willReturn([
            QualificationBackend(backend: "claude", installed: true), QualificationBackend(backend: "codex", installed: true)
        ])
        given(useCase).qualificationSession().willProduce { queue.next() }
        let vm = HarnessesVM(useCase: useCase)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.count == 2 && vm.qualificationCards.allSatisfy { $0.model.state == .failed } }
        // when
        vm.didTapQualification("codex:qualification")
        await waitUntil { vm.qualificationCards.contains { $0.owner == "codex" && $0.model.state == .ready } }
        // then
        #expect(Set(vm.qualificationCards.map(\.id)).count == 2)
        #expect(first.checks == 0)
        #expect(second.checks == 1)
        #expect(vm.qualificationCards.first(where: { $0.owner == "claude" })?.model.state == .failed)
        #expect(vm.qualificationCards.first(where: { $0.owner == "claude" })?.model.identity == "Claude")
        vm.didDisappear()
    }

    @Test func givenCheckingSettingsHarness_whenCancelTapped_thenCancelledWithoutClaimingEngineStopped() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let gate = QualificationCheckGate()
        let session = QualificationSession(repository: SuspendedQualificationFixture(base: fixture, gate: gate))
        let vm = make(fixture, session: session)
        vm.didAppear()
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        vm.didTapQualification("claude:settings/claude")
        await gate.waitForEntry()
        await waitUntil { vm.qualificationCards.first?.model.state == .checking }
        // when
        vm.didTapQualification("claude:settings/claude")
        await waitUntil { vm.qualificationCards.first?.model.state == .cancelled }
        await gate.open()
        // then
        #expect(await session.snapshot.phase == .cancelled)
        #expect(vm.qualificationCards.first?.model.message.contains("Late results") == true)
        vm.didDisappear()
    }

    // MARK: - Non-native harnesses and ordering

    private func make(catalog: [QualificationBackend], sessions: QualificationSessionQueue? = nil) -> (HarnessesVM, MockHarnessesUseCase) {
        let useCase = MockHarnessesUseCase()
        HarnessesVMTests.stubRuntime(useCase)
        given(useCase).status().willReturn(.failure(.launchFailed(tool: "fixture", detail: "Fixture registration status unavailable")))
        given(useCase).qualificationBackends().willReturn(catalog)
        if let sessions {
            given(useCase).qualificationSession().willProduce { sessions.next() }
        } else {
            given(useCase).qualificationSession().willProduce { QualificationSession(repository: QualificationFixture()) }
        }
        return (HarnessesVM(useCase: useCase), useCase)
    }

    @Test func givenANonNativeHarness_whenSettingsOpens_thenNoSessionIsDiscoveredAndTheNoNativeRowShows() async {
        // given
        let (vm, useCase) = make(catalog: [QualificationBackend(backend: "opencode", installed: true)])
        // when
        vm.didAppear()
        await waitUntil { !vm.qualificationNotes.isEmpty }
        // then
        #expect(vm.qualificationNotes == [QualificationNote(id: "opencode", identity: "Opencode",
                                                            text: "No native qualification for this harness", glyph: nil)])
        #expect(vm.qualificationCards.isEmpty)
        verify(useCase).qualificationSession().called(0)
        vm.didDisappear()
    }

    @Test func givenANonNativeHarnessNotInstalled_whenSettingsOpens_thenTheNotFoundRowShows() async {
        // given
        let (vm, _) = make(catalog: [QualificationBackend(backend: "antigravity", installed: false)])
        // when
        vm.didAppear()
        await waitUntil { !vm.qualificationNotes.isEmpty }
        // then
        #expect(vm.qualificationNotes.first?.text == "Antigravity was not found on PATH. Install it, then refresh.")
        #expect(vm.qualificationNotes.first?.glyph == .unavailable)
        #expect(vm.qualificationCards.isEmpty)
        vm.didDisappear()
    }

    @Test func givenMixedCatalog_whenSettingsOpens_thenNativeCardsComeFirstInCatalogOrder() async {
        // given
        let (vm, useCase) = make(catalog: [
            QualificationBackend(backend: "vibe", installed: true),
            QualificationBackend(backend: "opencode", installed: true),
            QualificationBackend(backend: "claude", installed: true),
            QualificationBackend(backend: "antigravity", installed: false),
            QualificationBackend(backend: "codex", installed: true)
        ])
        // when
        vm.didAppear()
        await waitUntil { vm.qualificationCards.count == 3 && vm.qualificationNotes.count == 2 }
        // then
        #expect(vm.qualificationCards.compactMap(\.owner) == ["vibe", "claude", "codex"])
        #expect(vm.qualificationNotes.map(\.id) == ["opencode", "antigravity"])
        verify(useCase).qualificationSession().called(3)
        vm.didDisappear()
    }

    @Test func givenNotesShowing_whenRuntimeLosesReadiness_thenCardsAndNotesAreCleared() async {
        // given
        let (vm, _) = make(catalog: [QualificationBackend(backend: "claude", installed: true),
                                     QualificationBackend(backend: "opencode", installed: true)])
        vm.didAppear()
        await waitUntil { vm.qualificationCards.count == 1 && vm.qualificationNotes.count == 1 }
        // when
        vm.setRuntimeReady(false)
        // then
        #expect(vm.qualificationCards.isEmpty)
        #expect(vm.qualificationNotes.isEmpty)
        vm.didDisappear()
    }
}
