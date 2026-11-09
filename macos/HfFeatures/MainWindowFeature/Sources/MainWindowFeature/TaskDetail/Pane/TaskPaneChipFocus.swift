//
//  TaskPaneChipFocus.swift
//  MainWindowFeature
//
//  Returning focus to a top bar chip after the pane it revealed closes. A chip is a toolbar item in its own AppKit
//  hosting view, so the SwiftUI focus bindings in the task view cannot reach it from the task view's hosting graph, and
//  AppKit hands focus to the first view of the key-view loop (the sidebar) when the focused group leaves the tree. The
//  return therefore has a native step: capture where focus was at the moment of the close, and after the pane has gone
//  move the first responder to the chip's own view, or, if the platform refuses, to the originating window. Every step
//  revalidates the request first, so a return never takes focus from a person who has moved on. The SwiftUI keyboard and
//  accessibility bindings stay in `TaskDetailView.returnFocus`; a notification is never the focus mechanism.
//

import AppKit
import SwiftUI

// MARK: - TaskPaneAccessibility

/// The pane's accessibility label, shared by the pane and the focus probe that recognises it in the accessibility tree.
enum TaskPaneAccessibility {
    static let paneLabel = "Task details"
}

// MARK: - PaneFocusSnapshot

/// Where focus was when the pane was asked to close, read before the pane leaves the tree.
struct PaneFocusSnapshot {
    /// The accessibility focus was on an element inside the pane. The SwiftUI group header is an accessibility element
    /// of a hosting view that is itself the first responder, so only the accessibility tree identifies it.
    var axFocusInPane: Bool
    /// The first responder was the task detail's hosting view, where SwiftUI keeps its focus when no assistive client is on.
    var nativeFocusInDetail: Bool
    /// The window of the mounted task view the close happened in.
    weak var window: NSWindow?
    /// The timestamp of the event being dispatched at the close; only input after it counts as the person moving on.
    var inputGate: TimeInterval = 0

    /// Focus was in the pane or the task detail, so the close displaced it and it should come back.
    var worthReturning: Bool { axFocusInPane || nativeFocusInDetail }
}

// MARK: - TaskPaneChipFocus

/// The decision and the steps of one native focus return. The surface is read again before each mutation.
@MainActor
enum TaskPaneChipFocus {

    /// Where the window's first responder is, relative to the chip and the task detail.
    enum Responder: Equatable, Sendable {
        /// On the chip's own view (or inside it).
        case chip
        /// The task detail's hosting view, where SwiftUI keeps its own focus.
        case detailHost
        /// Nothing in particular: the window itself, or no responder.
        case nowhere
        /// A view outside the task detail region: where AppKit puts focus when the focused view is removed.
        case outsideDetail
        /// A text editor, or a control inside the task detail region: something the person is using.
        case liveControl
    }

    /// What is true now. The default is "do not proceed".
    struct Surface: Equatable, Sendable {
        /// The close that asked for this return is still the latest pane change, on the same mounted pane.
        var requestIsCurrent = false
        /// The originating window is still the one the mounted task view is in.
        var sameWindow = false
        /// The originating window is the key window of an active application.
        var windowIsKey = false
        var sheetAttached = false
        /// A key or mouse press reached the application after the close.
        var userInputSinceClose = false
        var responder = Responder.liveControl
        /// The origin's toolbar item has exactly one suitable responder.
        var hasTarget = false
    }

    enum Reason: Equatable, Sendable {
        case notInPane, staleRequest, windowChanged, windowNotKey, sheetOpen, userInput, focusMoved
    }

    enum Outcome: Equatable, Sendable {
        case focusedChip
        case fellBackToWindow
        /// The platform refused both the chip and the window.
        case refused
        case skipped(Reason)
    }

    // MARK: - Mapping

    /// The toolbar item identifier of a chip origin; `nil` for the header controls inside the task view.
    static func toolbarIdentifier(for origin: TaskPaneController.Origin) -> String? {
        switch origin {
        case .chipContinuity: "task-detail.chip.continuity"
        case .chipNotices: "task-detail.chip.notices"
        case .chipAccess: "task-detail.chip.access"
        case .continuityDetails, .notices: nil
        }
    }

    /// The single visible view inside `chip` that accepts first responder; `nil` when there is none or more than one, so
    /// an ambiguous item is never guessed at and no other subtree is searched.
    static func uniqueResponder(in chip: NSView) -> NSView? {
        // A chip with a hidden ancestor outside this entry is not visible either.
        guard !chip.isHiddenOrHasHiddenAncestor else { return nil }
        var found: [NSView] = []
        func visit(_ view: NSView) {
            // A hidden view hides everything below it, so its subtree is not searched.
            guard !view.isHidden else { return }
            if view.acceptsFirstResponder { found.append(view) }
            view.subviews.forEach(visit)
        }
        visit(chip)
        return found.count == 1 ? found[0] : nil
    }

    // MARK: - Decision

    /// Why the return must not act on `surface`, `nil` when it may.
    static func veto(_ surface: Surface) -> Reason? {
        if !surface.requestIsCurrent { return .staleRequest }
        if !surface.sameWindow { return .windowChanged }
        if !surface.windowIsKey { return .windowNotKey }
        if surface.sheetAttached { return .sheetOpen }
        if surface.userInputSinceClose { return .userInput }
        if surface.responder == .liveControl { return .focusMoved }
        return nil
    }

    /// Runs one return: a deferral so the pane is gone, then the SwiftUI keyboard and accessibility bindings, a second
    /// deferral so they have applied, then the chip, then the window. `surface` is read before the bindings, before the chip
    /// and again before the window fallback, and every read must pass `veto`, so no step acts for a request that has gone
    /// stale, left its window, met user input or lost its mount. `applyBindings` performs the SwiftUI assignments and runs only
    /// after the first read passed; `focusChip` and `focusWindow` perform and verify the AppKit change.
    static func run(
        snapshot: PaneFocusSnapshot?,
        surface: @MainActor () -> Surface,
        applyBindings: @MainActor () -> Void,
        focusChip: @MainActor () -> Bool,
        focusWindow: @MainActor () -> Bool
    ) async -> Outcome {
        guard let snapshot, snapshot.worthReturning else { return .skipped(.notInPane) }
        await Task.yield()
        if case let .stopped(stop) = checkpoint(surface) { return stop }
        applyBindings()
        await Task.yield()
        let second: Surface
        switch checkpoint(surface) {
        case let .stopped(stop): return stop
        case let .ready(read): second = read
        }
        if second.responder == .chip { return .focusedChip }
        if second.hasTarget, focusChip() { return .focusedChip }
        // The chip took no focus (refused, or removed meanwhile): fall back to the window only if the request is still eligible.
        let third: Surface
        switch checkpoint(surface) {
        case let .stopped(stop): return stop
        case let .ready(read): third = read
        }
        if third.responder == .chip { return .focusedChip }
        if third.responder == .nowhere { return .fellBackToWindow }
        return focusWindow() ? .fellBackToWindow : .refused
    }

    /// The result of one checkpoint read: the surface to act on, or the outcome that ends the run.
    private enum Checkpoint {
        case ready(Surface)
        case stopped(Outcome)
    }

    /// One read that must pass: a cancelled task is stale, and a vetoed surface stops the run with its reason.
    private static func checkpoint(_ surface: @MainActor () -> Surface) -> Checkpoint {
        guard !Task.isCancelled else { return .stopped(.skipped(.staleRequest)) }
        let read = surface()
        if let reason = veto(read) { return .stopped(.skipped(reason)) }
        return .ready(read)
    }

    // MARK: - Accessibility ownership

    /// What the ownership check reads from the accessibility tree. Closures, so a test can supply two panes.
    struct AccessibilityReader {
        /// The element the application reports as accessibility-focused.
        var focused: @MainActor () -> NSObject?
        var label: @MainActor (NSObject) -> String?
        var parent: @MainActor (NSObject) -> NSObject?
        /// The element's frame in screen coordinates.
        var frame: @MainActor (NSObject) -> CGRect?
        /// The window the element reports being in, `nil` when it reports none.
        var window: @MainActor (NSObject) -> NSObject?
        /// Every pane-labelled element reachable from the originating window's own accessibility tree.
        var panesInOwner: @MainActor () -> [NSObject]
    }

    /// Whether the accessibility focus is inside THE pane of the mounted task view, not merely inside some element called
    /// "Task details". The pane found above the focused element must (1) have a positive frame inside `region`, the
    /// mounted anchor's screen rect, (2) not report a different window than `owner`, and (3) be proven the originating
    /// window's: either it is the very element (identity) found by traversing the originating window's own accessibility
    /// tree, or it positively reports `owner` as its window. A frame that equals an owned pane's frame is never proof: two
    /// windows can hold same-sized panes at the same screen position, and a node that reports no window is unidentified.
    /// Unknown ownership is not owned.
    static func focusIsInOwnedPane(_ reader: AccessibilityReader, owner: NSObject, region: CGRect) -> Bool {
        guard let focused = reader.focused() else { return false }
        var element = focused
        var pane: NSObject?
        for _ in 0 ..< 40 {
            if reader.label(element) == TaskPaneAccessibility.paneLabel {
                pane = element
                break
            }
            guard let parent = reader.parent(element) else { return false }
            element = parent
        }
        guard let pane, let frame = reader.frame(pane), frame.width > 0, frame.height > 0,
              region.insetBy(dx: -1, dy: -1).contains(frame) else { return false }
        for candidate in [pane, focused] {
            if let reported = reader.window(candidate), reported !== owner { return false }
        }
        if reader.window(pane) === owner { return true }
        return reader.panesInOwner().contains { $0 === pane || $0.isEqual(pane) }
    }
}

// MARK: - TaskPaneChipFocusHost

/// Owns the live side of one mounted standalone task view: its window (through an anchor view that fills the task
/// region), the close-time probe, the watch for input after the close and the running return. One per `TaskPaneHolder`.
@MainActor
final class TaskPaneChipFocusHost {
    /// Fills the task detail region; its window is the originating window.
    weak var anchor: NSView?
    private(set) var lastOutcome: TaskPaneChipFocus.Outcome?
    private var running: Task<Void, Never>?
    private var monitor: Any?
    private var inputSeen = false

    init() {}

    isolated deinit {
        running?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    // MARK: Probe

    /// Reads where focus is now. Called when the pane is asked to close, before it leaves the tree. It only reads: it starts
    /// no watch for input, so a close that never starts a native return (a header origin) leaves nothing running. The
    /// watch begins in `start`, from the gate recorded here.
    func probe() -> PaneFocusSnapshot {
        let gate = NSApplication.shared.currentEvent?.timestamp ?? 0
        guard let anchor, let window = anchor.window else {
            return PaneFocusSnapshot(axFocusInPane: false, nativeFocusInDetail: false, window: nil, inputGate: gate)
        }
        let region = window.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let axInPane = TaskPaneChipFocus.focusIsInOwnedPane(Self.liveReader(window: window), owner: window, region: region)
        let native = classify(window: window, chip: nil) == .detailHost
        return PaneFocusSnapshot(axFocusInPane: axInPane, nativeFocusInDetail: native, window: window, inputGate: gate)
    }

    /// The real accessibility tree of this process, with the pane search rooted in `window`'s own content.
    static func liveReader(window: NSWindow) -> TaskPaneChipFocus.AccessibilityReader {
        TaskPaneChipFocus.AccessibilityReader(
            focused: { object(NSApplication.shared, "accessibilityFocusedUIElement") },
            label: { object($0, "accessibilityLabel") as? String },
            parent: { object($0, "accessibilityParent") },
            frame: { frame(of: $0) },
            window: { object($0, "accessibilityWindow") },
            panesInOwner: { panes(in: window) }
        )
    }

    private static func object(_ target: NSObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        return target.perform(selector)?.takeUnretainedValue() as? NSObject
    }

    private static func frame(of element: NSObject) -> CGRect? {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard element.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = element.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return value.rectValue
    }

    /// Pane-labelled elements reachable from the window's content through accessibility children and subviews, bounded.
    private static func panes(in window: NSWindow) -> [NSObject] {
        guard let root = window.contentView else { return [] }
        var found: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        var visited = 0
        while let next = queue.popLast(), visited < 6000 {
            visited += 1
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            if object(next, "accessibilityLabel") as? String == TaskPaneAccessibility.paneLabel { found.append(next) }
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: kids)
            }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return found
    }

    // MARK: Return

    /// Starts the native return for a chip, replacing any earlier one, and begins watching for input from the snapshot's gate.
    /// `isCurrent` says the request is still the latest pane change of this mounted pane. `applyBindings` performs the SwiftUI
    /// keyboard and accessibility assignments for the origin; it runs only under the same eligibility as the native steps and
    /// never after `cancel()`.
    func start(identifier: String, snapshot: PaneFocusSnapshot?, isCurrent: @escaping @MainActor () -> Bool,
               applyBindings: @escaping @MainActor () -> Void) {
        running?.cancel()
        beginWatchingInput(gate: snapshot?.inputGate ?? 0)
        running = Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await TaskPaneChipFocus.run(
                snapshot: snapshot,
                surface: { self.surface(identifier: identifier, snapshot: snapshot, isCurrent: isCurrent) },
                applyBindings: applyBindings,
                focusChip: { self.focusChip(identifier: identifier, snapshot: snapshot) },
                focusWindow: { self.focusWindow(snapshot: snapshot) }
            )
            guard !Task.isCancelled else { return }
            lastOutcome = outcome
            stopWatchingInput()
        }
    }

    /// Whether the key and mouse watch is installed.
    var isWatchingInput: Bool { monitor != nil }

    /// Cancels a pending return: the mounted view is going away.
    func cancel() {
        running?.cancel()
        running = nil
        stopWatchingInput()
    }

    private func surface(identifier: String, snapshot: PaneFocusSnapshot?, isCurrent: () -> Bool) -> TaskPaneChipFocus.Surface {
        var surface = TaskPaneChipFocus.Surface()
        guard let window = snapshot?.window, let current = anchor?.window else { return surface }
        surface.requestIsCurrent = isCurrent()
        surface.sameWindow = current === window
        surface.windowIsKey = window.isKeyWindow && NSApplication.shared.isActive
        surface.sheetAttached = window.attachedSheet != nil
        surface.userInputSinceClose = inputSeen
        let chip = chipView(identifier: identifier, in: window)
        surface.hasTarget = chip.flatMap(TaskPaneChipFocus.uniqueResponder(in:)) != nil
        surface.responder = classify(window: window, chip: chip)
        return surface
    }

    /// The origin's toolbar item view, verified to belong to `window`.
    private func chipView(identifier: String, in window: NSWindow) -> NSView? {
        guard let view = window.toolbar?.items.first(where: { $0.itemIdentifier.rawValue == identifier })?.view,
              view.window === window, !view.isHiddenOrHasHiddenAncestor else { return nil }
        return view
    }

    private func classify(window: NSWindow, chip: NSView?) -> TaskPaneChipFocus.Responder {
        guard let responder = window.firstResponder, responder !== window else { return .nowhere }
        guard !(responder is NSText), let view = responder as? NSView else { return .liveControl }
        if let chip, view === chip || view.isDescendant(of: chip) { return .chip }
        guard let anchor else { return .outsideDetail }
        if anchor.isDescendant(of: view) { return .detailHost }
        let region = anchor.convert(anchor.bounds, to: nil)
        let frame = view.convert(view.bounds, to: nil)
        return region.contains(CGPoint(x: frame.midX, y: frame.midY)) ? .liveControl : .outsideDetail
    }

    /// Moves the first responder to the chip's one responder and verifies that the window agrees and that it is the chip's.
    private func focusChip(identifier: String, snapshot: PaneFocusSnapshot?) -> Bool {
        guard let window = snapshot?.window, let chip = chipView(identifier: identifier, in: window),
              let target = TaskPaneChipFocus.uniqueResponder(in: chip), window.makeFirstResponder(target) else { return false }
        return window.firstResponder === target && target.isDescendant(of: chip)
    }

    /// Makes the originating window itself the first responder, which overrides AppKit's fallback to the sidebar.
    private func focusWindow(snapshot: PaneFocusSnapshot?) -> Bool {
        guard let window = snapshot?.window, window.makeFirstResponder(nil) else { return false }
        return window.firstResponder === window
    }

    // MARK: Input

    /// Any key or mouse press after the close means the person is driving focus: the return then stands down. Events
    /// already being dispatched when the watch starts (the press that caused the close) do not count.
    private func beginWatchingInput(gate: TimeInterval) {
        stopWatchingInput()
        inputSeen = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            self?.noteInput(at: event.timestamp, after: gate)
            return event
        }
    }

    func noteInput(at timestamp: TimeInterval, after gate: TimeInterval) {
        if timestamp > gate { inputSeen = true }
    }

    private func stopWatchingInput() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

// MARK: - TaskPaneFocusAnchor

/// A transparent view behind the standalone mount that fills the task region and gives the host its window.
struct TaskPaneFocusAnchor: NSViewRepresentable {
    let host: TaskPaneChipFocusHost

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        host.anchor = view
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) { host.anchor = view }

    static func dismantleNSView(_ view: AnchorView, coordinator: ()) {}

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
