import AppKit
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowDeleteHostedTests

/// Desktop acceptance is intentionally deferred; run only through the guarded hosted lane.
@MainActor @Suite(.serialized) struct WorkflowDeleteHostedTests {
    @Test(arguments: [false, true], [false, true])
    func givenSavedEditor_whenReturnOrEscapeDismissesDelete_thenCancelPreservesDraft(dirty: Bool, escape: Bool) async throws {
        // given
        let (vm, store, _) = WorkflowConflictRecoveryTests().makeVM()
        if !dirty { vm.definition = vm.savedDefinition }
        vm.persistDraft()
        let before = try store.load(key: "saved:Saved")
        let page = RedesignHost(WorkflowDeleteHarness(vm: vm).withPresentationContext(), size: CGSize(width: 700, height: 400))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { page.element("Delete workflow") != nil }
        // when
        #expect(page.press(try #require(page.element("Delete workflow"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        let root = try #require(sheet.contentView)
        func element(_ label: String) -> NSObject? { page.elements(in: root).first { page.matches($0, label) } }
        await page.settle { element("Cancel") != nil }
        // then
        #expect(element("Delete workflow ‘Saved’?") != nil)
        #expect(element("Delete") != nil)
        #expect(sheet.defaultButtonCell?.title == "Cancel")
        let description = "Existing run snapshots remain available." + (dirty ? "\nUnsaved changes will be lost." : "")
        #expect(element(description) != nil)
        let characters = escape ? "\u{1B}" : "\r"
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: sheet.windowNumber, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: escape ? 53 : 36))
        NSApp.sendEvent(key)
        await page.settle { page.window.attachedSheet == nil }
        #expect(vm.deleteRequestID == nil)
        #expect(try store.load(key: "saved:Saved") == before)
    }
}

// MARK: - WorkflowDeleteHarness

private struct WorkflowDeleteHarness: View {
    @Environment(\.viewEvent) private var viewEvent
    @State var vm: WorkflowVM

    var body: some View {
        Button("Delete workflow") { vm.deleteWorkflow() }
            .publishViewEvent(from: vm, to: viewEvent)
    }
}
