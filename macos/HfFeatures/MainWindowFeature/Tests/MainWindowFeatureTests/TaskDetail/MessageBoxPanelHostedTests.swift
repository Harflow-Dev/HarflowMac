import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MessageBoxPanelHostedTests

@MainActor @Suite(.serialized)
struct MessageBoxPanelHostedTests {
    @Test func givenTwoPanelDrafts_whenCommandReturnIsPressed_thenOnlyTheFocusedPanelSubmits() async throws {
        // given
        var submitted: [(String, String)] = []
        let fixture = RedesignHost(VStack {
            MessageBoxView(model: model("First panel"), isCompact: true) {
                submitted.append(("first", $0)); return true
            }
            MessageBoxView(model: model("Second panel"), isCompact: true) {
                submitted.append(("second", $0)); return true
            }
        }, size: CGSize(width: 420, height: 500))
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.window.isKeyWindow }
        let first = try #require(field("First panel", in: fixture))
        let second = try #require(field("Second panel", in: fixture))
        #expect(fixture.window.makeFirstResponder(first))
        edit(first, text: "  first draft  ")
        await fixture.settle { first.stringValue == "  first draft  " }
        #expect(fixture.window.makeFirstResponder(second))
        edit(second, text: "  second draft  ")
        await fixture.settle { second.currentEditor() != nil }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ))

        // when
        #expect(fixture.window.performKeyEquivalent(with: event))
        await fixture.settle { !submitted.isEmpty }

        // then
        #expect(submitted.count == 1)
        #expect(submitted.first?.0 == "second")
        #expect(submitted.first?.1 == "  second draft  ")
        #expect(first.stringValue == "  first draft  ")
    }

    private func model(_ placeholder: String) -> MessageBoxModel {
        MessageBoxModel(canSend: true, canContinue: false, isBusy: false, label: placeholder,
                        hint: "Send queues the message", placeholder: placeholder, buttonLabel: "Send")
    }

    private func field(_ placeholder: String, in fixture: RedesignHost) -> NSTextField? {
        fixture.descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == placeholder }
    }

    private func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        field.currentEditor()?.string = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }
}
