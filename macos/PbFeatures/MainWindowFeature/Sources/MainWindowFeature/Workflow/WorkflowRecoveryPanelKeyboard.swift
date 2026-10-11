import AppKit
import PbUI
import SwiftUI

// MARK: - WorkflowRecoveryPanelKeyboard

/// The recovery panel's scoped native Escape bridge (user amendment). A feature-local AppKit
/// local key monitor — never a global shortcut or an OS keyboard-navigation change — may
/// consume an unmodified Escape only while the actual first responder is a real control of the
/// mounted panel in the same window, because the native text editor may consume Escape before
/// any SwiftUI exit command can run. Every other key event passes through untouched, and
/// marked text keeps its native input-method composition cancellation.
@MainActor
final class WorkflowRecoveryPanelKeyboard {
    /// The macOS Escape key code.
    private static let escapeKeyCode: UInt16 = 53
    /// The user-driven modifiers an "unmodified" Escape must not carry.
    private static let modifiedMask: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    private var monitor: Any?
    private weak var panelRoot: NSView?
    private var onEscape: (() -> Void)?

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// True while the monitor is watching the given mounted panel root.
    func isAttached(panelRoot: NSView) -> Bool {
        self.panelRoot === panelRoot && monitor != nil
    }

    /// Installs the monitor for the mounted panel root. Re-attaching replaces the previous
    /// monitor, so a stale window or a rebuilt panel can never leave two behind.
    func attach(panelRoot: NSView, onEscape: @escaping () -> Void) {
        detach()
        self.panelRoot = panelRoot
        self.onEscape = onEscape
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    /// Removes the monitor and forgets the panel root; called on unmount, close and disposal.
    func detach() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        panelRoot = nil
        onEscape = nil
    }

    /// Consumes only an unmodified Escape whose first responder belongs to the mounted panel
    /// in the same window. Native ancestry, never geometric overlap, establishes ownership.
    /// Anything else — canvas and
    /// connection editing, other windows, modified Escape, and every non-Escape key — passes
    /// through unchanged. A first responder with marked text (active input-method
    /// composition) always keeps its native Escape cancellation.
    func handle(_ event: NSEvent) -> NSEvent? {
        guard let panelRoot,
              let window = panelRoot.window,
              let responder = window.firstResponder as? NSView
        else { return event }
        guard Self.shouldDismiss(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                 isSameWindow: event.window === window,
                                 responderBelongsToPanel: Self.responderBelongsToPanel(responder, panelRoot: panelRoot),
                                 hasMarkedText: (responder as? NSTextView)?.hasMarkedText() == true) else { return event }
        onEscape?()
        return nil
    }

    /// Pure key policy shared by native dispatch and focused IME/modifier/window checks.
    static func shouldDismiss(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, isSameWindow: Bool,
                              responderBelongsToPanel: Bool, hasMarkedText: Bool) -> Bool {
        keyCode == escapeKeyCode && modifiers.isDisjoint(with: modifiedMask)
            && isSameWindow && responderBelongsToPanel && !hasMarkedText
    }

    /// Shared field editors belong to their public delegate control; ordinary responders must
    /// be descendants of the owned native container, even when their visible bounds are clipped.
    static func responderBelongsToPanel(_ responder: NSView, panelRoot: NSView) -> Bool {
        if responder === panelRoot || responder.isDescendant(of: panelRoot) { return true }
        guard let editor = responder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSView, field.window === panelRoot.window else { return false }
        return field.isDescendant(of: panelRoot)
    }
}

#if DEBUG
#Preview("Owned recovery panel - light") {
    WorkflowRecoveryPanelContainer(onEscape: {}) {
        ScrollView { WorkflowRecoveryForm(viewModel: WorkflowPreview.make(run: true), onClose: {}) }
    }
    .frame(width: PbRadius.Metrics.recoveryPanelIdealWidth, height: PbRadius.Metrics.recoveryPanelInitialHeight)
    .preferredColorScheme(.light)
}

#Preview("Owned recovery panel - long, dark") {
    WorkflowRecoveryPanelContainer(onEscape: {}) {
        ScrollView { WorkflowRecoveryForm(viewModel: WorkflowPreview.makeLongQuestionRun(), onClose: {}) }
    }
    .frame(width: PbRadius.Metrics.recoveryPanelIdealWidth, height: PbRadius.Metrics.recoveryPanelInitialHeight)
    .preferredColorScheme(.dark)
}
#endif

// MARK: - WorkflowRecoveryPanelContainer

/// An owned native panel subtree, built with public NSHostingView APIs. Its size is only the
/// panel's actual bounds; the surrounding overlay never becomes an interactive backdrop.
struct WorkflowRecoveryPanelContainer<Content: View>: NSViewRepresentable {
    var onEscape: () -> Void
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> WorkflowRecoveryPanelRootView {
        let view = WorkflowRecoveryPanelRootView(frame: .zero)
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: WorkflowRecoveryPanelRootView, context: Context) {
        // Carry the presenting feature's environment, including presentation events and motion,
        // across the native hosting boundary. Updating rootView preserves its SwiftUI identity.
        view.host.rootView = AnyView(content().environment(\.self, context.environment))
        view.onEscape = onEscape
        view.syncKeyboard()
    }

    static func dismantleNSView(_ view: WorkflowRecoveryPanelRootView, coordinator _: Void) {
        view.keyboard.detach()
        view.onEscape = nil
    }
}

// MARK: - WorkflowRecoveryPanelRootView

/// Owns the complete native panel/editor ancestry and the bounded local-key monitor lifetime.
@MainActor
final class WorkflowRecoveryPanelRootView: NSView {
    let host = NSHostingView(rootView: AnyView(EmptyView()))
    let keyboard = WorkflowRecoveryPanelKeyboard()
    var onEscape: (() -> Void)?
    private weak var monitoredWindow: NSWindow?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(host)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(frame:)") }

    override func layout() {
        super.layout()
        host.frame = bounds
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncKeyboard()
    }

    func syncKeyboard() {
        guard let window else {
            keyboard.detach()
            monitoredWindow = nil
            return
        }
        guard monitoredWindow !== window || !keyboard.isAttached(panelRoot: self) else { return }
        monitoredWindow = window
        keyboard.attach(panelRoot: self) { [weak self] in self?.onEscape?() }
    }
}
