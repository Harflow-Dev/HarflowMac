import Combine
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct NewSessionComposerStateTests {
    private func make(
        catalog: BackendCatalog = .init(entries: [BackendControlFixtures.entry("claude")], state: .available),
        catalogSubject: PassthroughSubject<BackendCatalog, Never>? = nil,
        runGate: QualificationCheckGate? = nil
    ) -> (NewSessionVM, MockNewSessionUseCase, MockNewSessionRouting) {
        let useCase = MockNewSessionUseCase()
        let routing = MockNewSessionRouting()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).backendCatalog.willReturn(catalog)
        given(useCase).backendCatalogPublisher().willReturn(catalogSubject?.eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher())
        given(useCase).tasks.willReturn([])
        given(useCase).models(for: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).resolvedRepoPath(.any).willProduce { $0 }
        given(routing).didStart(taskID: .any).willReturn()
        given(routing).reviewRecent().willReturn()
        let composerUseCase: any NewSessionUseCase = if let runGate {
            GatedComposerUseCase(base: useCase, gate: runGate)
        } else {
            useCase
        }
        let vm = NewSessionVM(useCase: composerUseCase, routing: routing)
        vm.didAppear()
        vm.didChangeRepo("/fixture/repo")
        vm.didChangeMessage("Original draft")
        return (vm, useCase, routing)
    }

    @Test(arguments: [
        ToolError.timedOut(tool: "harflow-ctl", seconds: 75),
        .unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "no task_id"),
        .unknownOutcome(message: "Acknowledged task but listing failed"),
        .refused(code: "future_refusal", message: "Unclassified refusal"),
        .refused(code: "start_failed", message: "Unclassified launch failure")
    ])
    func givenAnUncertainDispatch_whenRemountedAndNewTaskRequested_thenDraftStaysFrozenAndCannotReplay(_ error: ToolError) async {
        // given
        let (vm, useCase, routing) = make()
        given(useCase).run(.any, runtime: .any).willThrow(error)
        vm.didChangeModel("custom-model")
        vm.didChangeName("Retained title")
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        vm.didTapStart()
        await waitUntil { vm.composerState == .unknown }
        vm.didDisappear()
        vm.didAppear()
        vm.prepareForNewTask()
        vm.didChangeMessage("Replacement")
        vm.didChangeModel("replacement-model")
        vm.didTapReviewSettings()
        vm.didTapStart()
        vm.didTapReviewRecent()
        // then
        #expect(vm.composerState == .unknown)
        #expect(vm.optionsLocked && vm.canReviewRecent && !vm.canReviewSettings && !vm.canStart)
        #expect(vm.message == "Original draft" && vm.model == "custom-model" && vm.name == "Retained title")
        verify(useCase).run(.any, runtime: .any).called(1)
        verify(routing).didStart(taskID: .any).called(0)
        verify(routing).reviewRecent().called(1)
        vm.didDisappear()
    }

    @Test(arguments: ["", " \n\t"])
    func givenABlankAcknowledgement_whenRunReturns_thenOutcomeIsUnknownAndNotRouted(_ id: String) async {
        // given
        let (vm, useCase, routing) = make()
        given(useCase).run(.any, runtime: .any).willReturn(id)
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        await waitUntil { !vm.isStarting }
        // then
        #expect(vm.composerState == .unknown && vm.optionsLocked)
        verify(routing).didStart(taskID: .any).called(0)
        vm.didDisappear()
    }

    @Test func givenADefinitiveInvalidRequestRefusal_whenReviewingSettings_thenOnlyExplicitReviewUnlocksDraft() async {
        // given
        let (vm, useCase, routing) = make()
        defer { withExtendedLifetime(routing) {} }
        given(useCase).run(.any, runtime: .any).willThrow(ToolError.refused(code: "invalid_params", message: "Refused before start"))
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        await waitUntil { vm.composerState == .refused }
        vm.didChangeMessage("Ignored until reviewed")
        // then
        #expect(vm.message == "Original draft" && vm.canReviewSettings && !vm.canReviewRecent)
        vm.didTapReviewSettings()
        #expect(vm.composerState == .editable && vm.message == "Original draft")
        vm.didChangeMessage("Reviewed draft")
        #expect(vm.message == "Reviewed draft")
        #expect(!vm.canStart) // every option edit invalidates qualification synchronously
        verify(useCase).run(.any, runtime: .any).called(1)
        vm.didDisappear()
    }

    @Test func givenAnAcknowledgedTask_whenDoubleTappedAndRemounted_thenRoutesExactlyOnceUntilExplicitNewIntent() async {
        // given
        let (vm, useCase, routing) = make()
        given(useCase).run(.any, runtime: .any).willReturn("task-acknowledged")
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        vm.didTapStart()
        await waitUntil { vm.composerState == .created }
        vm.didDisappear()
        vm.didAppear()
        vm.didTapStart()
        // then
        #expect(vm.composerState == .created && !vm.canStart)
        verify(useCase).run(.any, runtime: .any).called(1)
        verify(routing).didStart(taskID: .value("task-acknowledged")).called(1)
        vm.prepareForNewTask()
        #expect(vm.composerState == .editable && vm.message.isEmpty)
        vm.didDisappear()
    }

    @Test func givenRepositoryChoices_whenReturningAfterAnAcknowledgedStart_thenWindowMemoryRestoresEveryChoice() async {
        // given
        let (vm, useCase, routing) = make()
        defer { withExtendedLifetime(routing) {} }
        given(useCase).run(.any, runtime: .any).willReturn("task-memory")
        vm.didChangeModel("custom-not-in-catalog")
        vm.didChangeFreedom("publish")
        vm.didChangeEffort("high")
        vm.didChangeTurnLimit("27")
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        await waitUntil { vm.composerState == .created }
        vm.prepareForNewTask()
        vm.didChangeRepo("/fixture/other")
        vm.didChangeModel("other")
        vm.didChangeFreedom("read_only")
        vm.didChangeEffort("")
        vm.didChangeTurnLimit("")
        vm.didChangeRepo("/fixture/repo")
        // then
        #expect(vm.model == "custom-not-in-catalog" && vm.freedom == "publish")
        #expect(vm.effort == "high" && vm.turnLimit == "27" && !vm.callerApprovals)
        let (secondWindow, _, _) = make()
        #expect(secondWindow.model.isEmpty && secondWindow.turnLimit.isEmpty && secondWindow.freedom == "read_only")
        vm.didDisappear()
        secondWindow.didDisappear()
    }

    @Test func givenASubmittedRequest_whenOptionsAndLifecycleChange_thenCapturedRequestIsUnchangedAndSingleFlight() async {
        // given
        let gate = QualificationCheckGate()
        let (vm, useCase, routing) = make(runGate: gate)
        given(useCase).run(.any, runtime: .any).willReturn("task-once")
        vm.didChangeName("Original title")
        vm.didChangeTurnLimit("9")
        await waitUntil { vm.canStart }
        // when
        vm.didTapStart()
        await gate.waitForEntry()
        #expect(vm.composerState == .submitting)
        vm.didChangeRepo("/replacement")
        vm.didChangeName("Replacement title")
        vm.didChangeFreedom("unrestricted")
        vm.didChangeCallerApprovals(true)
        vm.didDisappear()
        vm.didAppear()
        vm.didTapStart()
        // then
        #expect(vm.composerState == .submitting && vm.optionsLocked)
        #expect(vm.repo == "/fixture/repo" && vm.name == "Original title" && vm.freedom == "read_only")
        verify(useCase)
.run(.matching {
            $0.repo == "/fixture/repo" && $0.title == "Original title" && $0.maxTurns == 9
                && $0.prompt == "Original draft" && !$0.callerApprovals
        }, runtime: .any)
.called(1)
        await gate.open()
        await waitUntil { vm.composerState == .created }
        verify(routing).didStart(taskID: .value("task-once")).called(1)
        vm.didDisappear()
    }

    @Test func givenUnsupportedCallerApprovals_whenRequested_thenValueIsPreservedAndStartBlocked() {
        // given
        let (vm, useCase, routing) = make()
        defer { withExtendedLifetime(routing) {} }
        // when
        vm.didChangeCallerApprovals(true)
        vm.didChangeBackend("vibe")
        vm.didTapStart()
        // then
        #expect(vm.callerApprovals)
        #expect(vm.callerApprovalError != nil && !vm.canStart)
        verify(useCase).run(.any, runtime: .any).called(0)
        vm.didDisappear()
    }

    @Test func givenAStartedLoadingCatalogDefault_whenCatalogArrivesDuringDispatchAndUnknown_thenSubmittedChoicesNeverChange() async {
        // given
        let subject = PassthroughSubject<BackendCatalog, Never>()
        let gate = QualificationCheckGate()
        let (vm, useCase, routing) = make(catalog: .init(entries: [], state: .loading), catalogSubject: subject, runGate: gate)
        given(useCase).run(.any, runtime: .any).willThrow(ToolError.unknownOutcome(message: "Launch owner did not answer"))
        let submittedBackend = vm.backend
        // Only defaults reach Start while the harness list is loading: model, effort and turn limit
        // cannot be checked until the catalog is available.
        vm.didChangeFreedom("publish")
        vm.didChangeName("Captured title")
        await waitUntil { vm.canStart }
        // when: the first real catalog arrives only after dispatch crossed the launch boundary.
        vm.didTapStart()
        await gate.waitForEntry()
        subject.send(.init(entries: [.init(backend: "codex", installed: true)], state: .available))
        await waitUntil { vm.agentOptions.contains { $0.id == "codex" } }
        // then
        #expect(vm.composerState == .submitting)
        #expect(vm.backend == submittedBackend && vm.model.isEmpty)
        #expect(vm.freedom == "publish" && vm.effort.isEmpty && vm.turnLimit.isEmpty && !vm.callerApprovals)
        #expect(vm.message == "Original draft" && vm.name == "Captured title")
        await gate.open()
        await waitUntil { vm.composerState == .unknown }
        subject.send(.init(entries: [.init(backend: "vibe", installed: true)], state: .available))
        await waitUntil { vm.agentOptions.contains { $0.id == "vibe" } }
        vm.didDisappear()
        vm.didAppear()
        vm.prepareForNewTask()
        vm.didTapStart()
        #expect(vm.composerState == .unknown && vm.optionsLocked)
        #expect(vm.backend == submittedBackend && vm.model.isEmpty)
        #expect(vm.freedom == "publish" && vm.effort.isEmpty && vm.turnLimit.isEmpty && !vm.callerApprovals)
        #expect(vm.message == "Original draft" && vm.name == "Captured title")
        verify(useCase)
.run(.matching {
            $0.backend == submittedBackend && $0.model == nil && $0.freedom == "publish"
                && $0.reasoningEffort == nil && $0.title == "Captured title" && $0.maxTurns == nil && !$0.callerApprovals
        }, runtime: .any)
.called(1)
        verify(useCase).run(.any, runtime: .any).called(1)
        verify(routing).didStart(taskID: .any).called(0)
        vm.didDisappear()
    }

}

/// Mockable's synchronous producers cannot suspend. This forwarding boundary records the exact
/// mocked request, then retains its result behind an explicit async gate without blocking MainActor.
@MainActor
private final class GatedComposerUseCase: NewSessionUseCase {
    private let base: MockNewSessionUseCase
    private let gate: QualificationCheckGate

    init(base: MockNewSessionUseCase, gate: QualificationCheckGate) {
        self.base = base
        self.gate = gate
    }

    func qualificationSession() -> QualificationSession { base.qualificationSession() }
    func resolvedRepoPath(_ input: String) -> String? { base.resolvedRepoPath(input) }
    var tasks: [TaskInfo] { base.tasks }
    var agentUsageSnapshot: AgentUsageSnapshot { base.agentUsageSnapshot }
    func agentUsagePublisher() -> AnyPublisher<AgentUsageSnapshot, Never> { base.agentUsagePublisher() }
    var backendCatalog: BackendCatalog { base.backendCatalog }
    func backendCatalogPublisher() -> AnyPublisher<BackendCatalog, Never> { base.backendCatalogPublisher() }
    func models(for backend: String) async -> [ModelOption] { await base.models(for: backend) }

    func run(_ request: RunRequest, runtime: QualificationRuntimeToken) async throws -> String {
        let result: Result<String, Error>
        do {
            result = .success(try await base.run(request, runtime: runtime))
        } catch {
            result = .failure(error)
        }
        await gate.wait()
        return try result.get()
    }
}
