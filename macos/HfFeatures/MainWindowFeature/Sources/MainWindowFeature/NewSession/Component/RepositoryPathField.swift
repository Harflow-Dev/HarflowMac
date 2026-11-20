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
        context.coordinator.owner = view
        flush.register(context.coordinator)
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.update(field: self, view: view)
        view.setAccessibilityHelp(help)
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
        /// The editor's bytes at end-editing, kept until flush, the deferred blur task or new editing consumes them.
        private var capturedText: String?
        /// The last bytes the view model is known to hold for this field, so a re-render never overwrites newer typing.
        private var lastDelivered: String

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
            let invalidated = selection != self.selection || isEditable != self.isEditable
            if invalidated {
                invalidate()
                self.selection = selection
                self.isEditable = isEditable
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
            guard canFlush, let (owner, editor) = trackedEditor(for: notification), let window = owner.window else { return }
            capturedText = editor.string
            cancelDeparture()
            self.editor = nil
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

        func invalidate() {
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
