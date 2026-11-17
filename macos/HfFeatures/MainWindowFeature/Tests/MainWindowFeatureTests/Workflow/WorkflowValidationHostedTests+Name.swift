import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - Workflow first-save name

extension WorkflowValidationHostedTests {
    nonisolated static let nameSurfaces = [
        WorkflowValidationSurface(isDark: false, size: CGSize(width: 1000, height: 620)),
        WorkflowValidationSurface(isDark: true, size: CGSize(width: 1000, height: 620)),
        WorkflowValidationSurface(isDark: false, size: CGSize(width: 1280, height: 800)),
        WorkflowValidationSurface(isDark: true, size: CGSize(width: 1280, height: 800))
    ]

    @Test(arguments: nameSurfaces)
    func givenNewWorkflow_whenTypingNameThenBlurring_thenActualTitleBindingValidatesAndPreservesDraft(surface: WorkflowValidationSurface) async throws {
        // given
        let useCase = ControlledWorkflowValidationUseCase()
        let store = WorkflowDraftTests().store()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: store, visibility: FakeMonitorVisibility(), scheduler: CapturingScheduler())
        vm.newWorkflow()
        let fixture = nameHost(vm, surface: surface)
        defer { fixture.close(); vm.didDisappear(); useCase.finishAllValidations() }
        let field = try await nameField(fixture)
        #expect(vm.validationState == .nameRequired)
        #expect(!vm.canSave)
        // when: operate the actual native title field through its production binding.
        try #require(fixture.window.makeFirstResponder(field))
        typeName("Release checklist", into: field)
        await fixture.settle { vm.name == "Release checklist" }
        #expect(vm.validationState == .checking)
        #expect(!vm.canSave)
        try #require(await useCase.waitForRequestCount(1))
        let validation = vm.validationTask
        useCase.finish(0, result: .success(["valid": .bool(true)]))
        await validation?.value
        await fixture.settle { (try? store.load(key: "new"))?["name"] == .string("Release checklist") }
        // then
        #expect(vm.canSave)
        #expect(try store.load(key: "new")?["name"] == .string("Release checklist"))
        try #require(fixture.window.makeFirstResponder(nil))
        #expect(vm.name == "Release checklist")
        #expect(vm.canSave)
        // when / then: an empty edit immediately revokes the exact validated draft.
        typeName("  ", into: field)
        await fixture.settle { vm.name == "  " }
        #expect(vm.validationState == .nameRequired)
        #expect(!vm.canSave)
    }

    @Test(arguments: nameSurfaces)
    func givenNewWorkflowWithLongName_whenTitleIsMounted_thenNativeFieldFitsAndSavedTitleIsStatic(surface: WorkflowValidationSurface) async throws {
        // given
        let vm = WorkflowPreview.make(run: false)
        vm.didDisappear()
        vm.loadedName = ""
        vm.isEditing = true
        vm.name = "Release checklist for desktop applications and their independently versioned engines"
        let fixture = nameHost(vm, surface: surface)
        defer { fixture.close(); vm.didDisappear() }
        // when
        let field = try await nameField(fixture)
        try #require(fixture.window.makeFirstResponder(field))
        // then
        let frame = field.convert(field.bounds, to: nil)
        #expect(frame.width >= 96 && frame.width <= 261)
        #expect(frame.minX >= 0 && frame.maxX <= surface.size.width + 1)
        #expect(field.stringValue == vm.name)
        // when / then: first save completion removes editing; no saved rename field is introduced.
        vm.loadedName = vm.name
        await fixture.settle { !fixture.descendants.compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "New workflow" } }
        #expect(fixture.element("Workflow name") == nil)
        #expect(fixture.hasElement(containing: vm.name))
    }

    private func nameHost(_ vm: WorkflowVM, surface: WorkflowValidationSurface) -> RedesignHost {
        RedesignHost(WorkflowNameHostedContent(viewModel: vm)
            .padding()
            .frame(width: surface.size.width, height: surface.size.height)
            .background(Color(nsColor: .windowBackgroundColor)), size: surface.size, appearance: surface.isDark ? .dark : .light)
    }

    private func nameField(_ fixture: RedesignHost) async throws -> NSTextField {
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        await fixture.settle { fixture.element("Workflow name") != nil }
        return try #require(fixture.descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "New workflow" })
    }

    private func typeName(_ value: String, into field: NSTextField) {
        field.stringValue = value
        field.currentEditor()?.string = value
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
}

// MARK: - WorkflowNameHostedContent

private struct WorkflowNameHostedContent: View {
    @State var viewModel: WorkflowVM

    var body: some View {
        VStack {
            HStack {
                WorkflowView(viewModel).workflowTitle
                Spacer()
                WorkflowView(viewModel).saveButton
            }
            WorkflowValidationStatus(viewModel: viewModel)
        }
    }
}
