import AppKit
import Combine
import SwiftUI

// MARK: - TaskStopSheetDismissal

/// Owns one exact native sheet independently of the lifetime of its SwiftUI content.
@MainActor
final class TaskStopSheetDismissal {
    private(set) var isDetached = false
    private let sheet: NSWindow
    private weak var parent: NSWindow?
    private var observation: AnyCancellable?
    private var completion: (() -> Void)?

    init?(window: NSWindow, completion: @escaping () -> Void) {
        guard let parent = window.sheetParent, parent.attachedSheet === window else { return nil }
        self.sheet = window
        self.parent = parent
        self.completion = completion
        self.observation = NotificationCenter.default
.publisher(for: NSWindow.didEndSheetNotification, object: parent)
            .sink { [weak self] _ in
                DispatchQueue.main.async { [weak self] in self?.didEndSheet() }
            }
    }

    private func didEndSheet() {
        // An older or unrelated notification cannot dismiss a still-attached captured sheet.
        guard sheet.sheetParent == nil, parent?.attachedSheet !== sheet else { return }
        isDetached = true
        let callback = completion
        completion = nil
        observation = nil
        callback?()
    }
}

// MARK: - TaskStopSheetAttachment

/// Reports only an actual native sheet attached to its presenting window.
struct TaskStopSheetAttachment: NSViewRepresentable {
    let attached: (NSWindow) -> Void

    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.attached = attached
        view.reportAttachment()
    }

    final class AnchorView: NSView {
        var attached: (NSWindow) -> Void = { _ in }
        private weak var reportedWindow: NSWindow?
        private var observation: AnyCancellable?

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.observation = NotificationCenter.default
.publisher(for: NSWindow.willBeginSheetNotification)
                .merge(with: NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))
                .sink { [weak self] _ in
                    DispatchQueue.main.async { [weak self] in self?.reportAttachment() }
                }
        }

        required init?(coder: NSCoder) { nil }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            reportAttachment()
        }

        override func layout() {
            super.layout()
            reportAttachment()
        }

        func reportAttachment() {
            guard let window, window !== reportedWindow,
                  let parent = window.sheetParent, parent.attachedSheet === window else { return }
            reportedWindow = window
            attached(window)
        }
    }
}
