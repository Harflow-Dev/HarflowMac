//
//  TaskPaneHostSupport.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - PaneMocks

/// Preview-model fixtures for the standalone mount. They carry the evidence the pane reads: the task, a matching
/// snapshot (or none), notices, continuity.
@MainActor enum PaneMocks {
    static let taskID = "abc12345"

    static func timeline() -> TimelinePaneModel {
        ActivityFeedTranscriptStyleHostedTests.timelineModel([
            ActivityFixture.text(1, "The retry path already re-checks the count, so no change was needed there.", task: taskID),
            ActivityFixture.separator("Also check the slot release path.", task: taskID),
            ActivityFixture.text(2, "Slot release notifies waiters inside the lock now.", task: taskID)
        ])
    }

    private static func inspector(task: TaskInfo, hasSnapshot: Bool, notices: [String]) -> InspectorModel {
        InspectorModel(
            task: task, current: nil, stepCount: 1, activity: ActivityCounts(), subtaskCount: 0, ancestors: [], siblings: [],
            detail: task, hasSnapshot: hasSnapshot, notices: notices, startedBy: "Top-level task",
            resumeCommand: nil, onCopyResumeCommand: {}, onCopyTaskID: {}, onSelectTask: { _ in }
        )
    }

    /// A running task with an optional notice list and no continuity.
    static func running(notices: [String] = []) -> TaskDetailViewModelMock {
        let mock = TaskDetailViewModelMock()
        mock.timelineModel = timeline()
        mock.inspectorModel = inspector(task: mock.task!, hasSnapshot: true, notices: notices)
        return mock
    }

    /// A finished task. `exit` is the exit code its snapshot observed; `nil` leaves the snapshot without one.
    static func done(exit: Int? = 0, hasSnapshot: Bool = true, notices: [String] = []) -> TaskDetailViewModelMock {
        let mock = TaskDetailViewModelMock.finished()
        mock.timelineModel = timeline()
        var raw = mock.task!.raw
        if let exit { raw["exit_code"] = .number(Double(exit)) }
        let task = TaskInfo(.object(raw))!
        mock.task = task
        mock.inspectorModel = inspector(task: task, hasSnapshot: hasSnapshot, notices: notices)
        return mock
    }

    /// A running task that shows the continuity line, and optionally notices.
    static func continuity(notices: [String] = []) -> TaskDetailViewModelMock {
        let mock = TaskDetailViewModelMock.continuity(notices: notices)
        mock.timelineModel = timeline()
        return mock
    }

    static func standalone(_ mock: TaskDetailViewModelMock, store: TaskPaneStateStore, conversation: String = "conv")
        -> some View {
        TaskDetailView(mock, chrome: .standalone, paneBinding: TaskPaneBinding(store: store, conversationID: conversation),
                       transcriptStyle: .transcript)
            .environment(\.hfReduceMotionOverride, true)
            .id(conversation)
    }
}

// MARK: - PaneHost

/// A hosted window with accessibility helpers for the pane. Close it with `close()`.
@MainActor final class PaneHost {
    let page: RedesignHost

    init(_ view: some View, size: CGSize, dark: Bool = false) {
        self.page = RedesignHost(view.preferredColorScheme(dark ? .dark : .light), size: size, appearance: dark ? .dark : .light)
    }

    func close() { page.close() }

    /// Pumps layout and the run loop for a number of passes, so SwiftUI geometry callbacks have all landed.
    func pump(_ passes: Int = 25) async {
        var done = 0
        await page.settle { done += 1; return done >= passes }
    }

    func resize(to size: CGSize) {
        page.window.setContentSize(size)
        page.host.frame = CGRect(origin: .zero, size: size)
    }

    var pane: NSObject? { page.element("Task details") }
    var paneFrame: CGRect? { pane.flatMap { page.frame($0) } }
    var hasPane: Bool { pane != nil }

    /// The accessibility modal flag of an element.
    func isModal(_ element: NSObject) -> Bool {
        let selector = NSSelectorFromString("isAccessibilityModal")
        if element.responds(to: selector) {
            typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
            return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
        }
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.isAccessibilityModal() }
        return false
    }

    /// The width of the transcript column: the activity table's scroll view, in host coordinates.
    var columnWidth: CGFloat? {
        guard let scroll = ActivityFeedTranscriptStyleHostedTests.tables(page.host).first?.enclosingScrollView else { return nil }
        return scroll.convert(scroll.bounds, to: page.host).width
    }

    /// Every accessibility element in the window.
    var allElements: [NSObject] { page.descendants.flatMap { page.elements(in: $0) } }

    func string(_ object: NSObject, _ property: String) -> String? { page.string(object, property) }

    /// The facts group headers (elements whose value is Expanded or Collapsed) as `(label, value)`.
    var groupHeaders: [(label: String, value: String)] {
        allElements.compactMap { element in
            guard let value = string(element, "accessibilityValue"), value == "Expanded" || value == "Collapsed" else { return nil }
            return (string(element, "accessibilityLabel") ?? "", value)
        }
    }

    /// The header element of a group, found by the start of its label.
    func header(_ title: String) -> NSObject? {
        allElements.first {
            let value = string($0, "accessibilityValue")
            guard value == "Expanded" || value == "Collapsed" else { return false }
            return string($0, "accessibilityLabel")?.hasPrefix(title) == true
        }
    }

    func headerValue(_ title: String) -> String? { header(title).flatMap { string($0, "accessibilityValue") } }

    /// The label of the element the application reports as focused, `nil` when none is.
    var focusedLabel: String? {
        let focused = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")) as? NSObject
        return focused.flatMap { string($0, "accessibilityLabel") }
    }

    /// How a key event reaches the pane: through `NSApplication.sendEvent`, which runs local event monitors, or straight to
    /// `NSWindow.sendEvent`, which skips them and reaches the window's key-equivalent pass.
    enum KeyPath: CaseIterable, CustomTestStringConvertible {
        case application, window
        var testDescription: String { self == .application ? "local monitor" : "performKeyEquivalent" }
    }

    /// Builds a key-down event for a window, Escape by default.
    func keyEvent(keyCode: UInt16 = 53, characters: String = "\u{1B}", modifiers: NSEvent.ModifierFlags = [],
                  isRepeat: Bool = false, windowNumber: Int? = nil) -> NSEvent? {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber ?? page.window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters,
                         isARepeat: isRepeat, keyCode: keyCode)
    }

    /// Sends an Escape key press along the chosen path.
    func sendEscape(via path: KeyPath = .application, modifiers: NSEvent.ModifierFlags = [], isRepeat: Bool = false,
                    windowNumber: Int? = nil) {
        guard let event = keyEvent(modifiers: modifiers, isRepeat: isRepeat, windowNumber: windowNumber) else { return }
        switch path {
        case .application: NSApp.sendEvent(event)
        case .window: (event.window ?? page.window).sendEvent(event)
        }
    }

    /// The escape monitor views in the hierarchy.
    var monitorViews: [PaneEscapeMonitor.MonitorView] {
        allViews(page.host).compactMap { $0 as? PaneEscapeMonitor.MonitorView }
    }

    func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    /// Scroll views that lie inside the pane's frame.
    func paneScrollViews() -> [NSScrollView] {
        guard let frame = paneFrame else { return [] }
        return allViews(page.host).compactMap { $0 as? NSScrollView }.filter {
            let rect = $0.convert($0.bounds, to: nil)
            return rect.width > 100 && frame.insetBy(dx: -2, dy: -2).contains(rect)
        }
    }
}
