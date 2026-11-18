import AppKit
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowDiscardHostedTests

@MainActor @Suite(.serialized) struct WorkflowDiscardHostedTests {
    @Test(arguments: [false, true])
    func givenFreshSavedRevision_whenReturnOrEscapeDismissesNativeConfirmation_thenCancelPreservesDraft(escape: Bool) async throws {
        // given
        let (vm, store, _) = WorkflowConflictRecoveryTests().makeVM()
        let before = try store.load(key: "saved:Saved")
        let page = RedesignHost(WorkflowDiscardHarness(vm: vm).withPresentationContext(), size: CGSize(width: 700, height: 400))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { page.element("Discard edits") != nil }
        // when
        #expect(page.press(try #require(page.element("Discard edits"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        let root = try #require(sheet.contentView)
        func element(_ label: String) -> NSObject? { page.elements(in: root).first { page.matches($0, label) } }
        await page.settle { element("Cancel") != nil }
        // then
        #expect(element("Discard unsaved changes?") != nil)
        #expect(element("The workflow returns to revision 2, its last saved revision.") != nil)
        #expect(element("Discard") != nil)
        #expect(sheet.defaultButtonCell?.title == "Cancel")
        let characters = escape ? "\u{1B}" : "\r"
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                              windowNumber: sheet.windowNumber, context: nil, characters: characters,
                                              charactersIgnoringModifiers: characters, isARepeat: false, keyCode: escape ? 53 : 36))
        NSApp.sendEvent(key)
        await page.settle { page.window.attachedSheet == nil }
        #expect(page.window.attachedSheet == nil)
        #expect(vm.discardRequestID == nil)
        #expect(vm.revision == 1)
        #expect(try store.load(key: "saved:Saved") == before)
    }
}

// MARK: - WorkflowDiscardHarness

private struct WorkflowDiscardHarness: View {
    @Environment(\.viewEvent) private var viewEvent
    @State var vm: WorkflowVM

    var body: some View {
        Button("Discard edits") { vm.discardChanges() }
            .publishViewEvent(from: vm, to: viewEvent)
    }
}
