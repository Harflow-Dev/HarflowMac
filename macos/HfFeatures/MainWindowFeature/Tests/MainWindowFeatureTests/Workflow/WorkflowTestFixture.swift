import Combine
import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore

@MainActor
extension WorkflowTests {
    func makeVM(qualification: QualificationFixture = QualificationFixture(gated: false),
                session: QualificationSession? = nil) -> (sut: WorkflowVM, useCase: MockWorkflowUseCase) {
        let useCase = MockWorkflowUseCase()
        given(useCase).qualificationSession().willReturn(session ?? QualificationSession(repository: qualification))
        let routing = MockWorkflowRouting()
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true)])
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).recordAgentUsage(.any, acknowledgementID: .any).willReturn()
        given(useCase).refreshTasks().willReturn()
        given(routing).chooseDirectory().willReturn(nil)
        given(routing).selectTask(.any).willReturn()
        given(routing).didSaveWorkflow(name: .any).willReturn()
        given(routing).openWorkflowEditor(name: .any).willReturn()
        let store = WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut, draftStore: store,
                visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        return (vm, useCase)
    }

}
