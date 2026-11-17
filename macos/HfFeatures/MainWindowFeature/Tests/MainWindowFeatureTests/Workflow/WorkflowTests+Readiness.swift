import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Workflow readiness

extension WorkflowTests {
    @Test(arguments: [[:], ["valid": JSONValue.string("true")], ["valid": JSONValue.bool(false)]])
    func givenUnprovenValidation_whenResponseArrives_thenSaveRemainsDisabled(response: [String: JSONValue]) async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = readinessVM(useCase)
        vm.name = "Draft"
        try #require(await useCase.waitForRequestCount(1))
        let task = vm.validationTask
        // when
        useCase.finish(0, result: .success(response))
        await task?.value
        // then
        #expect(!vm.canSave)
        #expect(vm.validationState == .invalid("Workflow is invalid."))
        #expect(vm.validatedDefinition == nil)
        vm.didDisappear()
    }

    @Test func givenUnavailableValidator_whenRetrySucceeds_thenCurrentDefinitionAloneBecomesReady() async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = readinessVM(useCase)
        vm.name = "Draft"
        try #require(await useCase.waitForRequestCount(1))
        let firstTask = vm.validationTask
        useCase.finish(0, result: .failure(ToolError.notFound(tool: "harflow-ctl", searched: [])))
        await firstTask?.value
        #expect(!vm.canSave)
        #expect(vm.validationState.accessibilityLabel == "Validation unavailable")
        #expect(vm.validationMessage?.contains("uv tool") == false)
        // when
        vm.scheduleValidation()
        #expect(vm.validationState == .checking)
        try #require(await useCase.waitForRequestCount(2))
        let secondTask = vm.validationTask
        useCase.finish(1, result: .success(["valid": .bool(true)]))
        await secondTask?.value
        // then
        #expect(vm.canSave)
        #expect(vm.validatedDefinition == vm.effectiveDefinition)
        vm.didDisappear()
    }

    @Test func givenExactValidatedDraft_whenOtherSaveGatesChange_thenEachStillRefusesSave() async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = readinessVM(useCase)
        vm.name = "Draft"
        try #require(await useCase.waitForRequestCount(1))
        let task = vm.validationTask
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await task?.value
        #expect(vm.canSave)
        // when / then
        vm.isBusy = true
        #expect(!vm.canSave)
        vm.isBusy = false
        vm.editorConflict = "Changed"
        #expect(!vm.canSave)
        vm.editorConflict = nil
        vm.checkingEditorBaseline = true
        #expect(!vm.canSave)
        vm.checkingEditorBaseline = false
        vm.initialLoadingKind = "editor"
        #expect(!vm.canSave)
        vm.initialLoadingKind = nil
        vm.initialLoadFailed = true
        #expect(!vm.canSave)
        vm.initialLoadFailed = false
        vm.loadedName = vm.name
        vm.savedDefinition = vm.definition
        #expect(!vm.canSave)
        vm.loadedName = ""
        #expect(vm.canSave)
        vm.name = " \n "
        #expect(!vm.canSave)
        #expect(vm.validationState == .nameRequired)
        vm.didDisappear()
    }

    @Test func givenValidatedDraft_whenEdited_thenReadinessRevokesBeforeNextRequestStarts() async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = readinessVM(useCase)
        vm.name = "Draft"
        try #require(await useCase.waitForRequestCount(1))
        let task = vm.validationTask
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await task?.value
        #expect(vm.canSave)
        // when
        vm.definition["description"] = .string("Changed")
        // then
        #expect(!vm.canSave)
        #expect(vm.validationState == .checking)
        #expect(vm.validatedDefinition == nil)
        #expect(useCase.requests.count == 1)
        vm.didDisappear()
    }

    @Test func givenValidatedName_whenNativeEditingWritesSameName_thenReadinessAndDraftWorkStayUnchanged() async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let vm = readinessVM(useCase)
        vm.newWorkflow()
        vm.name = "Release checklist"
        try #require(await useCase.waitForRequestCount(1))
        let validation = vm.validationTask
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await validation?.value
        await vm.draftWriteTask?.value
        let generation = vm.validationID
        let validatedDefinition = vm.validatedDefinition
        let historyCount = vm.editHistory.count
        let currentName = vm.name
        #expect(vm.canSave)
        // when: native end-editing may write the already bound value again.
        vm.name = currentName
        // then
        #expect(vm.canSave)
        #expect(vm.validationState == .valid)
        #expect(vm.validationID == generation)
        #expect(vm.validatedDefinition == validatedDefinition)
        #expect(vm.editHistory.count == historyCount)
        #expect(vm.draftWriteTask == nil)
        #expect(useCase.requests.count == 1)
        vm.didDisappear()
    }

    private func readinessVM(_ useCase: ControlledWorkflowValidationUseCase) -> WorkflowVM {
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftTests().store(), visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.definition = WorkflowVM.starterDefinition()
        return vm
    }
}
