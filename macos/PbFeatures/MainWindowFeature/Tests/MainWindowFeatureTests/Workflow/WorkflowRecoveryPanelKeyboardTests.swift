import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - WorkflowRecoveryPanelKeyboardTests

@MainActor @Suite(.serialized) struct WorkflowRecoveryPanelKeyboardTests {
    @Test func givenKeyPolicyInputs_whenCheckingDismissal_thenOnlyOwnedUnmodifiedEscapeWithoutIMEIsAccepted() {
        // given
        let cases: [(UInt16, NSEvent.ModifierFlags, Bool, Bool, Bool)] = [
            (53, [], true, true, false), (53, .command, true, true, false),
            (49, [], true, true, false), (53, [], false, true, false),
            (53, [], true, false, false), (53, [], true, true, true)
        ]

        // when / then
        for (keyCode, modifiers, sameWindow, belongs, markedText) in cases {
            let result = WorkflowRecoveryPanelKeyboard.shouldDismiss(
                keyCode: keyCode, modifiers: modifiers, isSameWindow: sameWindow,
                responderBelongsToPanel: belongs, hasMarkedText: markedText
            )
            #expect(result == (keyCode == 53 && modifiers.isDisjoint(with: [.command, .option, .control, .shift])
                               && sameWindow && belongs && !markedText))
        }
    }

    @Test func givenClippedEditorDescendant_whenCheckingOwnership_thenItBelongsToPanel() {
        // given
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let clip = NSClipView(frame: CGRect(x: 0, y: 0, width: 100, height: 40))
        let editor = NSTextView(frame: CGRect(x: -40, y: -80, width: 180, height: 160))
        panel.addSubview(clip)
        clip.addSubview(editor)

        // when / then — ancestry, not visible geometry, establishes ownership.
        #expect(WorkflowRecoveryPanelKeyboard.responderBelongsToPanel(editor, panelRoot: panel))
    }

    @Test func givenOverlappingOutsideControl_whenCheckingOwnership_thenItDoesNotBelongToPanel() {
        // given
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let outside = NSButton(frame: panel.bounds)

        // when / then — geometric overlap cannot grant Escape ownership.
        #expect(!WorkflowRecoveryPanelKeyboard.responderBelongsToPanel(outside, panelRoot: panel))
    }

    @Test func givenFieldEditorDelegatedToPanelControl_whenCheckingOwnership_thenItBelongsToPanel() {
        // given
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let field = RecoveryFieldView(frame: CGRect(x: 10, y: 10, width: 100, height: 24))
        let editor = NSTextView(frame: field.bounds)
        editor.isFieldEditor = true
        editor.delegate = field
        panel.addSubview(field)

        // when / then — shared field editors inherit ownership from their public delegate.
        #expect(WorkflowRecoveryPanelKeyboard.responderBelongsToPanel(editor, panelRoot: panel))
    }

    @Test func givenMountedPanel_whenEscapeIsHandled_thenItConsumesOnlyOwnedEventAndDetachesCleanly() throws {
        // given
        _ = NSApplication.shared
        let panel = NSView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let editor = NSTextView(frame: panel.bounds)
        panel.addSubview(editor)
        let window = NSWindow(contentRect: panel.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = panel
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        #expect(window.makeFirstResponder(editor))
        let keyboard = WorkflowRecoveryPanelKeyboard()
        var dismissed = false
        keyboard.attach(panelRoot: panel) { dismissed = true }
        #expect(keyboard.isAttached(panelRoot: panel))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))

        // when
        let result = keyboard.handle(event)

        // then
        #expect(result == nil)
        #expect(dismissed)
        keyboard.detach()
        #expect(!keyboard.isAttached(panelRoot: panel))
    }

    @Test func givenMarkedTextOrWrongWindow_whenCheckingPolicy_thenEscapePassesThrough() {
        // when / then
        #expect(!WorkflowRecoveryPanelKeyboard.shouldDismiss(
            keyCode: 53, modifiers: [], isSameWindow: true,
            responderBelongsToPanel: true, hasMarkedText: true
        ))
        #expect(!WorkflowRecoveryPanelKeyboard.shouldDismiss(
            keyCode: 53, modifiers: [], isSameWindow: false,
            responderBelongsToPanel: true, hasMarkedText: false
        ))
    }

    @Test func givenOwnedPanelRoot_whenWindowUnmounts_thenItsLocalMonitorIsRemoved() {
        // given
        _ = NSApplication.shared
        let root = WorkflowRecoveryPanelRootView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFront(nil)
        root.syncKeyboard()

        // when
        #expect(root.keyboard.isAttached(panelRoot: root))
        window.contentView = nil
        root.syncKeyboard()

        // then — detaching the owned root cannot leave a local monitor behind.
        #expect(!root.keyboard.isAttached(panelRoot: root))
        window.close()
    }
}

private final class RecoveryFieldView: NSView, NSTextViewDelegate {}
