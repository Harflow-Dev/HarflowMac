import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

/// `WorkflowVM` mirrors the engine-reported harness controls from the backend catalog.
@MainActor
@Suite struct WorkflowBackendControlsTests {
    private func makeVM(
        initial: BackendCatalog = .empty
    ) -> (vm: WorkflowVM, subject: PassthroughSubject<BackendCatalog, Never>) {
        let useCase = MockWorkflowUseCase()
        let subject = PassthroughSubject<BackendCatalog, Never>()
        given(useCase).backendCatalog.willReturn(initial)
        given(useCase).backendCatalogPublisher().willReturn(subject.eraseToAnyPublisher())
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(useCase).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(
            useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler()
        )
        return (vm, subject)
    }

    private func catalog(_ names: [String], state: BackendCatalogState = .available) -> BackendCatalog {
        BackendCatalog(entries: names.map { BackendControlFixtures.entry($0) }, state: state)
    }

    @Test func givenAnAvailableCatalogAtInit_whenCreated_thenControlsAreSeededSynchronously() {
        // given / when
        let (vm, _) = makeVM(initial: catalog(["claude", "vibe"]))
        // then
        #expect(vm.backendControls["claude"]?.turnCap == .supported)
        #expect(vm.backendControls["vibe"]?.model == .unsupported)
    }

    @Test func givenALoadingCatalog_whenCreated_thenEveryListedControlIsUnknown() {
        // given / when
        let (vm, _) = makeVM(initial: BackendCatalog(entries: [BackendControlFixtures.entry("claude")], state: .loading))
        // then
        #expect(vm.backendControls["claude"] == .unavailable)
    }

    @Test func givenTheViewAppears_whenACatalogArrivesLate_thenControlsUpdate() async {
        // given
        let (vm, subject) = makeVM()
        vm.didAppear()
        defer { vm.didDisappear() }
        #expect(vm.backendControls.isEmpty)
        // when
        subject.send(catalog(["codex"]))
        // then
        await waitUntil { vm.backendControls["codex"] != nil }
        #expect(vm.backendControls["codex"]?.turnCap == .unsupported)
        #expect(vm.backendControls["codex"]?.effort == .levels(["low", "medium", "high", "xhigh"]))
    }

    @Test func givenControls_whenTheCatalogDegrades_thenEveryEntryReadsUnknownAgain() async {
        // given
        let (vm, subject) = makeVM(initial: catalog(["claude"]))
        vm.didAppear()
        defer { vm.didDisappear() }
        // when
        subject.send(BackendCatalog(entries: [BackendCatalogEntry(backend: "claude", installed: nil)], state: .degraded))
        // then
        await waitUntil { vm.backendControls["claude"] == .unavailable }
        #expect(vm.backendControls["claude"] == .unavailable)
    }

    @Test func givenTheViewDisappears_whenACatalogArrives_thenNothingChangesUntilItReappears() async {
        // given
        let (vm, subject) = makeVM()
        vm.didAppear()
        vm.didDisappear()
        // when
        subject.send(catalog(["claude"]))
        await Task.yield()
        // then — no subscription is held while the view is gone
        #expect(vm.backendControls.isEmpty)
        vm.didAppear()
        defer { vm.didDisappear() }
        subject.send(catalog(["claude"]))
        await waitUntil { vm.backendControls["claude"] != nil }
        #expect(vm.backendControls["claude"] != nil)
    }
}
