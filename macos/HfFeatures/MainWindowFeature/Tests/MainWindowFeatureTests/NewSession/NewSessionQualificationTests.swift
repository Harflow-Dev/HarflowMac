import Combine
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
struct NewSessionQualificationTests {
    private func make(_ fixture: QualificationFixture,
                      catalog: BackendCatalog = .init(entries: [.init(backend: "fixture", installed: true)], state: .available),
                      subject: PassthroughSubject<BackendCatalog, Never>? = nil,
                      session: QualificationSession? = nil) -> (NewSessionVM, MockNewSessionUseCase, MockNewSessionRouting) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        given(useCase).qualificationSession().willReturn(session ?? QualificationSession(repository: fixture))
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).backendCatalogPublisher().willReturn(subject?.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
        given(useCase).tasks.willReturn([])
        given(useCase).models(for: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).resolvedRepoPath(.any).willReturn("/fixture/repo")
        given(useCase).run(.any, runtime: .any).willReturn("fixture-task")
        given(routing).didStart(taskID: .any).willReturn()
        let vm = NewSessionVM(useCase: useCase, routing: routing)
        vm.didAppear()
        vm.didChangeRepo("/fixture/repo")
        vm.didChangeMessage("Fixture prompt")
        return (vm, useCase, routing)
    }

    @Test func givenReadyRequiredEvidence_whenStarting_thenRunsUnchangedRequestAfterCachedPreflight() async {
        // given
        let (vm, useCase, routing) = make(QualificationFixture())
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        await waitUntil { !vm.isStarting }
        // then
        verify(useCase).run(.matching { $0.freedom == "read_only" && $0.prompt == "Fixture prompt" && !$0.callerApprovals }, runtime: .any).called(1)
        verify(routing).didStart(taskID: .value("fixture-task")).called(1)
        vm.didDisappear()
    }

    @Test func givenFailedRequiredEvidence_whenStarting_thenNoRunAndExplicitRetryCanRecover() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let (vm, useCase, _) = make(fixture)
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        // when
        vm.didTapStart()
        // then
        #expect(!vm.canStart)
        verify(useCase).run(.any, runtime: .any).called(0)
        #expect(vm.freedom == "read_only")
        fixture.setReady(true)
        vm.didTapQualification()
        await waitUntil { vm.canStart }
        #expect(fixture.checks == 1)
        #expect(vm.freedom == "read_only")
        vm.didDisappear()
    }

    @Test func givenUnsupportedEngine_whenOpening_thenExplicitUnsupportedAndNoRun() async {
        // given
        let (vm, useCase, _) = make(QualificationFixture(error: .unsupportedCommand(tool: "harflow-ctl", command: "qualification",
                                                                                     detail: "Fixture unsupported")))
        // when
        await waitUntil { vm.qualificationCards.first?.model.state == .unsupported }
        vm.didTapStart()
        // then
        #expect(!vm.canStart)
        verify(useCase).run(.any, runtime: .any).called(0)
        vm.didDisappear()
    }

    @Test func givenReadySelectedBackend_whenCatalogReplacesIt_thenOldReadinessInvalidatedBeforeRediscovery() async {
        // given
        let fixture = QualificationFixture()
        let subject = PassthroughSubject<BackendCatalog, Never>()
        let (vm, _, _) = make(fixture, subject: subject)
        await waitUntil { vm.canStart }
        fixture.setReady(false)
        // when
        subject.send(.init(entries: [.init(backend: "second", installed: true)], state: .available))
        await waitUntil { vm.backend == "second" }
        // then
        #expect(!vm.canStart)
        #expect(vm.qualificationCards.allSatisfy { !$0.model.identity.hasPrefix("Fixture") })
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        #expect(vm.qualificationCards.first?.model.identity.hasPrefix("Second") == true)
        #expect(fixture.checks == 0)
        vm.didDisappear()
    }

    @Test func givenKnownMissingHarnessWithNoRequiredFeatures_whenSheetOpens_thenUnavailableAndCannotStart() async {
        // given
        let catalog = BackendCatalog(entries: [.init(backend: "fixture", installed: false)], state: .available)
        let (vm, useCase, _) = make(QualificationFixture(gated: false), catalog: catalog)
        // when / then
        #expect(vm.qualificationCards.first?.model.state == .unavailable)
        #expect(!vm.canStart)
        vm.didTapStart()
        verify(useCase).run(.any, runtime: .any).called(0)
        vm.didDisappear()
    }

    @Test func givenCheckingHarness_whenCancelActionTapped_thenCancelledCardAndStartStayDisabled() async {
        // given
        let fixture = QualificationFixture(ready: false)
        let gate = QualificationCheckGate()
        let session = QualificationSession(repository: SuspendedQualificationFixture(base: fixture, gate: gate))
        let (vm, _, _) = make(fixture, session: session)
        await waitUntil { vm.qualificationCards.first?.model.state == .failed }
        vm.didTapQualification()
        await gate.waitForEntry()
        await waitUntil { vm.qualificationCards.first?.model.state == .checking }
        // when
        vm.didTapQualification()
        await waitUntil { vm.qualificationCards.first?.model.state == .cancelled }
        fixture.setReady(true)
        await gate.open()
        // then
        #expect(!vm.canStart)
        #expect(await session.snapshot.phase == .cancelled)
        vm.didDisappear()
    }

    @Test func givenExplicitEmptyBackend_whenQualificationFixtureDiscovers_thenStructuredRefusalInsteadOfTrap() async {
        // given
        let fixture = QualificationFixture(gated: false)
        // when / then
        do {
            let runtime = try fixture.runtimeToken()
            _ = try await fixture.discover(.task(options: ["--backend="]), runtime: runtime)
            Issue.record("An empty backend must not produce ready fixture evidence")
        } catch {
            guard case ToolError.refused(code: "invalid_backend", message: _) = error else {
                Issue.record("Expected explicit invalid-backend refusal, received \(error)")
                return
            }
        }
    }

}
