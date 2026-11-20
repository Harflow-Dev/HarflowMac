import AppKit
import SwiftUI

// MARK: - RepositoryPathField

/// The repository picker owns this control so edit completion follows the native field editor.
@MainActor
struct RepositoryPathField: NSViewRepresentable {
    @Environment(\.isEnabled) private var isEnabled
    @Binding var text: String
    let selectionGeneration: () -> Int
    let canEdit: () -> Bool
    let canFlush: () -> Bool
    let flush: RepositoryFieldFlush
    let help: String?
    let commit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(field: self) }

    func makeNSView(context: Context) -> NSTextField {
        let view = NSTextField(string: text)
        view.placeholderString = "/path/to/repo"
        view.bezelStyle = .roundedBezel
        view.cell?.usesSingleLineMode = true
        view.setAccessibilityLabel("Repository path")
        view.cell?.setAccessibilityLabel("Repository path")
        view.cell?.setAccessibilityIdentifier("repository-path-field")
        context.coordinator.owner = view
        flush.register(context.coordinator)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(field: self, view: view)
        view.setAccessibilityHelp(help)
        view.cell?.setAccessibilityHelp(help)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context _: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite else { return nil }
        return CGSize(width: width, height: nsView.intrinsicContentSize.height)
    }

    static func dismantleNSView(_ view: NSTextField, coordinator: Coordinator) {
        coordinator.invalidate()
        coordinator.unregister()
        coordinator.owner = nil
        view.delegate = nil
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        weak var owner: NSTextField?
        private weak var editor: NSTextView?
        private var field: RepositoryPathField
        private var selection: Int
        private var isEditable: Bool
        private var hasEdit = false
        private var departure: Task<Void, Never>?
        private var restoreTask: Task<Void, Never>?
        /// Advanced by every lock transition so intent from an earlier lock cycle can never be reused.
        private var lockToken = 0
        private var focusRestore: FocusRestore?
        /// The editor's bytes at end-editing, kept until flush, the deferred blur task or new editing consumes them.
        private var capturedText: String?
        /// The last bytes the view model is known to hold for this field, so a re-render never overwrites newer typing.
        private var lastDelivered: String

        /// What a lock took from the focused field, so unlocking can give the user their place back.
        private struct FocusRestore {
            let token: Int
            let selectedRange: NSRange
        }

        init(field: RepositoryPathField) {
            self.field = field
            self.selection = field.selectionGeneration()
            self.isEditable = field.isEnabled
            self.lastDelivered = field.text
        }

        private var acceptsCallbacks: Bool {
            isEditable && field.canEdit() && selection == field.selectionGeneration()
        }

        /// Unlike `acceptsCallbacks` this ignores presentation: dismissal flips it before the final bytes are read.
        private var canFlush: Bool {
            owner != nil && isEditable && selection == field.selectionGeneration() && field.canFlush()
        }

        func unregister() { field.flush.unregister(self) }

        func update(field: RepositoryPathField, view: NSTextField) {
            let selection = field.selectionGeneration()
            let isEditable = field.isEnabled
            self.field = field
            let locked = isEditable != self.isEditable
            let selectionChanged = selection != self.selection
            let invalidated = selectionChanged || locked
            // Read before invalidate() drops the tracked editor.
            let intent = locked ? restoreIntent(becomingEditable: isEditable, view: view) : nil
            if invalidated {
                invalidate()
                self.selection = selection
                self.isEditable = isEditable
            }
            if !selectionChanged, let intent {
                focusRestore = intent
                if isEditable { scheduleRestore(intent, view: view) }
            }

            // Install externally chosen bytes in the existing editor if it still owns focus, unless the editor holds
            // bytes the view model has not seen yet. A binding echo has identical bytes and must not change the
            // insertion point.
            if let activeEditor = view.currentEditor() as? NSTextView {
                let differs = !activeEditor.string.utf8.elementsEqual(field.text.utf8)
                if !differs {
                    lastDelivered = field.text
                } else if invalidated || activeEditor.string.utf8.elementsEqual(lastDelivered.utf8) {
                    activeEditor.string = field.text
                    lastDelivered = field.text
                }
                editor = isEditable ? activeEditor : nil
            } else if !view.stringValue.utf8.elementsEqual(field.text.utf8) {
                view.stringValue = field.text
                lastDelivered = field.text
            }
            view.isEnabled = isEditable
        }

        func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool {
            guard control === owner, acceptsCallbacks, let editor = fieldEditor as? NSTextView else { return false }
            cancelDeparture()
            capturedText = nil
            lastDelivered = field.text
            self.editor = editor
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let (owner, editor) = fieldEditor(for: notification),
                  owner.currentEditor() === editor, owner.window?.firstResponder === editor else { return }
            cancelDeparture()
            deliver(editor.string)
        }

        func controlTextDidEndEditing(_ notification: Notification) {
            guard let (owner, editor) = trackedEditor(for: notification) else { return }
            // Focus has left this editor whether or not delivery is still allowed; keeping it would let a later lock
            // snapshot a focus the field no longer has.
            self.editor = nil
            guard canFlush, let window = owner.window else { return }
            capturedText = editor.string
            cancelDeparture()
            departure = Task { @MainActor [weak self, weak owner, weak window] in
                guard !Task.isCancelled, let self, let owner, let window, self.owner === owner,
                      owner.window === window, owner.currentEditor() == nil, acceptsCallbacks else { return }
                departure = nil
                if let captured = capturedText { deliver(captured) }
                commitEdit()
            }
        }

        /// Hands undelivered bytes to the view model: the live editor's, or those captured at end-editing.
        /// Marked text is still being composed, so nothing is delivered for it.
        func flush() {
            guard canFlush else { return }
            if let editor, owner?.currentEditor() === editor {
                guard !editor.hasMarkedText() else { return }
                deliver(editor.string)
            } else if let captured = capturedText {
                deliver(captured)
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)),
                  acceptsCallbacks, let owner, control === owner, editor === textView,
                  owner.currentEditor() === textView, owner.window?.firstResponder === textView,
                  !textView.hasMarkedText() else { return false }
            let modifiers = NSApp.currentEvent?.modifierFlags ?? []
            guard modifiers.isDisjoint(with: [.command, .shift, .option, .control]) else { return false }
            deliver(textView.string)
            commitEdit()
            return true
        }

        private func fieldEditor(for notification: Notification) -> (NSTextField, NSTextView)? {
            acceptsCallbacks ? trackedEditor(for: notification) : nil
        }

        private func trackedEditor(for notification: Notification) -> (NSTextField, NSTextView)? {
            guard let owner, notification.object as AnyObject? === owner, let editor,
                  notification.userInfo?["NSFieldEditor"] as? NSTextView === editor else { return nil }
            return (owner, editor)
        }

        private func deliver(_ value: String) {
            capturedText = nil
            lastDelivered = value
            guard !value.utf8.elementsEqual(field.text.utf8) else { return }
            field.text = value
            hasEdit = true
        }

        private func commitEdit() {
            guard hasEdit else { return }
            hasEdit = false
            field.commit()
        }

        /// Advances the token for this lock transition. Locking a focused field takes a snapshot; unlocking carries it
        /// over only when it came from the immediately preceding lock.
        private func restoreIntent(becomingEditable: Bool, view: NSTextField) -> FocusRestore? {
            let earlier = focusRestore
            let earlierWasCurrent = earlier?.token == lockToken
            lockToken &+= 1
            focusRestore = nil
            if becomingEditable {
                guard let earlier, earlierWasCurrent else { return nil }
                return FocusRestore(token: lockToken, selectedRange: earlier.selectedRange)
            }
            // SwiftUI's host disables the control before updateNSView, which removes the live editor without an
            // end-editing notification; the tracked editor then still says the field had focus.
            guard let editor, view.currentEditor() === editor || view.currentEditor() == nil else { return nil }
            return FocusRestore(token: lockToken, selectedRange: editor.selectedRange)
        }

        /// Runs after the update that unlocked the field. It is one attempt: whatever the outcome, the intent is spent.
        /// Restoring writes and commits nothing; the editor it adopts holds exactly the view model's bytes.
        private func scheduleRestore(_ intent: FocusRestore, view: NSTextField) {
            restoreTask = Task { @MainActor [weak self, weak view, weak scheduledWindow = view.window] in
                guard !Task.isCancelled, let self, let view, owner === view,
                      focusRestore?.token == intent.token, lockToken == intent.token else { return }
                focusRestore = nil
                restoreTask = nil
                guard let window = view.window, window === scheduledWindow, window.isKeyWindow,
                      window.firstResponder == nil || window.firstResponder === window, isEditable, acceptsCallbacks, view.currentEditor() == nil,
                      window.makeFirstResponder(view), let editor = view.currentEditor() as? NSTextView else { return }
                guard editor.string.utf8.elementsEqual(field.text.utf8) else { return }
                self.editor = editor
                lastDelivered = field.text
                let length = editor.string.utf16.count
                let location = min(intent.selectedRange.location, length)
                editor.selectedRange = NSRange(location: location, length: min(intent.selectedRange.length, length - location))
            }
        }

        func invalidate() {
            restoreTask?.cancel()
            restoreTask = nil
            focusRestore = nil
            cancelDeparture()
            editor = nil
            hasEdit = false
            capturedText = nil
        }

        private func cancelDeparture() {
            departure?.cancel()
            departure = nil
        }
    }
}

#if DEBUG
#Preview("Repository path field") {
    RepositoryPathField(text: .constant("/path/to/repo"), selectionGeneration: { 0 },
                        canEdit: { true }, canFlush: { true }, flush: RepositoryFieldFlush(), help: nil, commit: {})
        .frame(width: 328)
        .padding()
}
#endif
