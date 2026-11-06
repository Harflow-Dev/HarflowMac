import AppKit
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - Fixture

@MainActor final class SidebarNativeBaselineFixture {
    let viewModel: SidebarViewModelMock
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    let navigationFrame: CGRect
    let promptViewModel: NewSessionViewModelMock
    let promptEditor: NSTextView
    let runningOutline: NSOutlineView
    let outline: NSOutlineView
    private let previousEnhancedInterface: Any?
    private let previousActivationPolicy: NSApplication.ActivationPolicy

    init() async throws {
        _ = NSApplication.shared
        self.previousActivationPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        self.viewModel = SidebarViewModelMock(sections: Self.fixtureSections())
        viewModel.savedWorkflows = [WorkflowRecord(raw: ["name": .string("baseline-definition")])]
        self.promptViewModel = NewSessionViewModelMock(message: "Baseline prompt first line\nBaseline prompt second line")
        let promptModel = promptViewModel
        let model = viewModel
        let root = AnyView(NavigationSplitView {
            SidebarView(model).navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 340)
        } detail: {
            NewSessionView(promptModel)
        }
.frame(minWidth: 640, minHeight: 760)
.withPresentationContext())
        self.controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        self.window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1000, height: 760),
            styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.toolbar = NSToolbar(identifier: "sidebar-native-baseline")
        window.toolbarStyle = .unified
        window.contentView = controller.view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let hostedView = controller.view
        let hostedWindow = window
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return NSApp.isActive && hostedWindow.isKeyWindow
                && Self.findNavigationFrame(in: hostedView) != nil
                && Self.findViews(hostedView).compactMap { $0 as? ComposerPromptScrollView }.count == 1
                && sidebarFixtureOutline(in: hostedView, role: .running) != nil
                && (sidebarFixtureOutline(in: hostedView)?.numberOfRows ?? 0) > 0
        }
        self.navigationFrame = try #require(Self.findNavigationFrame(in: hostedView))
        let promptScrollViews = Self.findViews(hostedView).compactMap { $0 as? ComposerPromptScrollView }
        try #require(promptScrollViews.count == 1)
        self.promptEditor = try #require(promptScrollViews.first?.promptTextView)
        try #require(promptEditor.isEditable && promptEditor.window === hostedWindow)
        self.runningOutline = try #require(sidebarFixtureOutline(in: hostedView, role: .running))
        #expect(!Self.findViews(hostedView).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })
        let foundOutline = try #require(sidebarFixtureOutline(in: hostedView))
        self.outline = foundOutline
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return foundOutline.numberOfRows >= 5
        }
    }

    private static func fixtureSections() -> [SidebarSection] {
        SidebarViewModelMock.defaultSections.map { section -> SidebarSection in
            guard section.bucket == .today else { return section }
            let workflow = TaskRowModel(
                id: "baseline-workflow", backend: "codex", title: "Baseline workflow",
                status: .completed, repoName: "repo", ageText: "1h"
            )
            let shortcut = TaskRowModel(
                id: "baseline-workflow", backend: "vibe", title: "Baseline shortcut",
                status: .failed, repoName: "repo", ageText: "2h", detailLabel: "Child workflow"
            )
            return SidebarSection(bucket: section.bucket, items: section.items + [
                .workflow(workflow), .workflowShortcut(shortcut, parentRunID: "baseline-parent")
            ])
        }
    }

    func close() {
        window.contentView = nil
        window.close()
        NSApp.setActivationPolicy(previousActivationPolicy)
        NSApplication.shared.accessibilitySetValue(
            previousEnhancedInterface,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
    }

    func observe() -> Baseline {
        controller.view.layoutSubtreeIfNeeded()
        let rowObservations = (0 ..< outline.numberOfRows).map { row in
            let rowView = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
            let realizedRowView = outline.rowView(atRow: row, makeIfNecessary: false)
            let item = outline.item(atRow: row)
            return RowObservation(
                index: row,
                identifier: String(describing: item),
                rect: outline.rect(ofRow: row),
                fittingHeight: rowView?.fittingSize.height ?? 0,
                isGroupItem: outline.delegate?.outlineView?(outline, isGroupItem: item),
                isGroupRowStyle: realizedRowView?.isGroupRowStyle,
                accessibility: Self.accessibilityTree(rowView)
            )
        }
        let missing = rowObservations.filter(\.accessibility.isEmpty).map(\.index)
        let keyboard = Dictionary(uniqueKeysWithValues: KeyboardProbe.allCases.map { probe in
            (probe.rawValue, send(probe))
        })
        let promptFocus = probePromptFocus()
        let aliases = aliasSelection()
        return Baseline(
            flags: Flags(
                allowsTypeSelect: outline.allowsTypeSelect,
                floatsGroupRows: outline.floatsGroupRows,
                indentationPerLevel: outline.indentationPerLevel,
                allowsMultipleSelection: outline.allowsMultipleSelection,
                allowsEmptySelection: outline.allowsEmptySelection,
                refusesFirstResponder: outline.refusesFirstResponder,
                selectionHighlightStyle: outline.selectionHighlightStyle.rawValue,
                rowSizeStyle: outline.rowSizeStyle.rawValue,
                style: outline.style.rawValue,
                frame: outline.frame,
                bounds: outline.bounds,
                contentInsets: EdgeInsetsRecord(outline.enclosingScrollView?.contentInsets
                    ?? NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0))
            ),
            rows: rowObservations,
            missingAccessibility: missing,
            keyboard: keyboard,
            promptFocus: promptFocus,
            aliasSelection: aliases,
            navigationFrame: FrameRecord(navigationFrame),
            scrollFrame: FrameRecord(outline.enclosingScrollView?.convert(
                outline.enclosingScrollView?.bounds ?? .zero, to: nil
            ) ?? .zero),
            firstRowFrame: FrameRecord(outline.convert(outline.rect(ofRow: 0), to: nil)),
            effectiveViewportBottom: (outline.enclosingScrollView?.contentInsets.bottom ?? 0)
                + (outline.enclosingScrollView?.convert(outline.enclosingScrollView?.bounds ?? .zero, to: nil).minY ?? 0),
            effectiveViewportTop: (outline.enclosingScrollView?.convert(outline.enclosingScrollView?.bounds ?? .zero, to: nil).maxY ?? 0)
                - (outline.enclosingScrollView?.contentInsets.top ?? 0),
            contentLayoutRect: FrameRecord(window.contentLayoutRect)
        )
    }

    func settle() async {
        var previous: [CGRect] = []
        var stablePasses = 0
        await waitUntil(timeout: 5) {
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            let current = (0 ..< outline.numberOfRows).map { outline.rect(ofRow: $0) }
            stablePasses = current == previous ? stablePasses + 1 : 0
            previous = current
            return stablePasses >= 6
        }
    }

    func write(_ baseline: Baseline) {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_SIDEBAR_NATIVE_BASELINE_OUTPUT"] else { return }
        let url = URL(fileURLWithPath: path)
        do {
            let data = try JSONEncoder().encode(baseline)
            try data.write(to: url, options: .atomic)
        } catch {
            Issue.record("Could not write sidebar baseline to \(path): \(error)")
        }
    }

    private func send(_ probe: KeyboardProbe) -> KeyboardObservation {
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let before = Array(outline.selectedRowIndexes)
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: probe.modifiers,
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: probe.characters, charactersIgnoringModifiers: probe.characters,
            isARepeat: false, keyCode: probe.keyCode
        )
        if let event { outline.keyDown(with: event) }
        controller.view.layoutSubtreeIfNeeded()
        return KeyboardObservation(
            selectedRowsBefore: before,
            selectedRowsAfter: Array(outline.selectedRowIndexes),
            firstResponder: outline.window?.firstResponder === outline,
            represented: event != nil
        )
    }

    private func probePromptFocus() -> PromptFocusObservation {
        // Seed both independent lists after the keyboard probes and before alias selection.
        runningOutline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let runningBefore = Array(runningOutline.selectedRowIndexes)
        let recentBefore = Array(outline.selectedRowIndexes)
        let textBefore = promptEditor.string
        let messageBefore = promptViewModel.message
        let requested = window.makeFirstResponder(promptEditor)
        let focusedBefore = window.firstResponder === promptEditor
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(0xF700)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0xF700)!), isARepeat: false, keyCode: 126
        )!
        window.sendEvent(event)
        return PromptFocusObservation(
            requestedFirstResponder: requested,
            arrowsKeptFocus: focusedBefore && window.firstResponder === promptEditor,
            nativeTextUnchanged: !textBefore.isEmpty && promptEditor.string == textBefore,
            modelMessageUnchanged: !messageBefore.isEmpty && promptViewModel.message == messageBefore,
            runningSelectionBefore: runningBefore,
            runningSelectionAfter: Array(runningOutline.selectedRowIndexes),
            recentSelectionBefore: recentBefore,
            recentSelectionAfter: Array(outline.selectedRowIndexes)
        )
    }

    private func aliasSelection() -> [Int] {
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet([2, 3]), byExtendingSelection: false)
        return Array(outline.selectedRowIndexes)
    }
}

// MARK: - Recorded values

struct Baseline: Codable {
    let flags: Flags
    let rows: [RowObservation]
    let missingAccessibility: [Int]
    let keyboard: [String: KeyboardObservation]
    let promptFocus: PromptFocusObservation
    let aliasSelection: [Int]
    let navigationFrame: FrameRecord
    let scrollFrame: FrameRecord
    let firstRowFrame: FrameRecord
    let effectiveViewportBottom: CGFloat
    let effectiveViewportTop: CGFloat
    let contentLayoutRect: FrameRecord
}

struct FrameRecord: Codable {
    let minX: CGFloat
    let minY: CGFloat
    let maxX: CGFloat
    let maxY: CGFloat

    init(_ rect: CGRect) {
        self.minX = rect.minX
        self.minY = rect.minY
        self.maxX = rect.maxX
        self.maxY = rect.maxY
    }
}

struct Flags: Codable {
    let allowsTypeSelect: Bool
    let floatsGroupRows: Bool
    let indentationPerLevel: CGFloat
    let allowsMultipleSelection: Bool
    let allowsEmptySelection: Bool
    let refusesFirstResponder: Bool
    let selectionHighlightStyle: Int
    let rowSizeStyle: Int
    let style: Int
    let frame: CGRect
    let bounds: CGRect
    let contentInsets: EdgeInsetsRecord
}

struct EdgeInsetsRecord: Codable, Equatable {
    let top: CGFloat
    let left: CGFloat
    let bottom: CGFloat
    let right: CGFloat

    init(top: CGFloat, left: CGFloat, bottom: CGFloat, right: CGFloat) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    init(_ insets: NSEdgeInsets) {
        self.top = insets.top
        self.left = insets.left
        self.bottom = insets.bottom
        self.right = insets.right
    }
}

struct RowObservation: Codable {
    let index: Int
    let identifier: String
    let rect: CGRect
    let fittingHeight: CGFloat
    /// Diagnostic only: native delegate classification is recorded for old/current comparisons.
    /// It is intentionally not asserted because the adapter may own group semantics differently.
    let isGroupItem: Bool?
    /// Diagnostic only: nil means AppKit had not realized a row view at the observation point.
    let isGroupRowStyle: Bool?
    let accessibility: [AXObservation]

    var stableAXSignature: [String] {
        var seen = Set<String>()
        return accessibility.compactMap { observation in
            let value = observation.value ?? ""
            guard !value.matchesDynamicClock else { return nil }
            guard !(observation.label ?? "").isEmpty || !(observation.value ?? "").isEmpty
                || !observation.actions.isEmpty else { return nil }
            let signature = [observation.role ?? "", observation.label ?? "", value,
                             observation.actions.joined(separator: ",")].joined(separator: "|")
            guard seen.insert(signature).inserted else { return nil }
            guard !signature.replacingOccurrences(of: "|", with: "").isEmpty else { return nil }
            return signature
        }
    }
}

struct AXObservation: Codable {
    let role: String?
    let label: String?
    let value: String?
    let actions: [String]
    let childCount: Int
}

struct KeyboardObservation: Codable {
    let selectedRowsBefore: [Int]
    let selectedRowsAfter: [Int]
    let firstResponder: Bool
    let represented: Bool
}

struct PromptFocusObservation: Codable {
    let requestedFirstResponder: Bool
    let arrowsKeptFocus: Bool
    let nativeTextUnchanged: Bool
    let modelMessageUnchanged: Bool
    let runningSelectionBefore: [Int]
    let runningSelectionAfter: [Int]
    let recentSelectionBefore: [Int]
    let recentSelectionAfter: [Int]
}

enum KeyboardProbe: String, CaseIterable, Hashable {
    case up, down, home, end, pageUp, pageDown, commandA, `return`, space, letter

    var characters: String {
        switch self {
        case .up: String(UnicodeScalar(0xF700)!)
        case .down: String(UnicodeScalar(0xF701)!)
        case .home: String(UnicodeScalar(0xF729)!)
        case .end: String(UnicodeScalar(0xF72B)!)
        case .pageUp: String(UnicodeScalar(0xF72C)!)
        case .pageDown: String(UnicodeScalar(0xF72D)!)
        case .commandA: "a"
        case .return: "\r"
        case .space: " "
        case .letter: "b"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .up: 126
        case .down: 125
        case .home: 115
        case .end: 119
        case .pageUp: 116
        case .pageDown: 121
        case .commandA: 0
        case .return: 36
        case .space: 49
        case .letter: 11
        }
    }

    var modifiers: NSEvent.ModifierFlags { self == .commandA ? .command : [] }
}

// MARK: - Native helpers

extension SidebarNativeBaselineFixture {
    static func findNavigationFrame(in view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        // The public semantic AX button supplies geometry independently of native focus.
        var seen = Set<ObjectIdentifier>()
        let buttons = accessibilityObjects(view).filter { object in
            seen.insert(ObjectIdentifier(object)).inserted
                && object.accessibilityObjectValue("accessibilityIdentifier") == "sidebar-navigation-New task"
                && object.accessibilityObjectValue("accessibilityRole") == "AXButton"
        }
        guard buttons.count == 1,
              let button = buttons.first,
              let frame = accessibilityFrameInWindow(button, window: window),
              !frame.isEmpty else { return nil }
        return frame
    }

    private static func accessibilityFrameInWindow(_ object: NSObject, window: NSWindow) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol {
            return window.convertFromScreen(accessible.accessibilityFrame())
        }
        // KVC boxes a virtual AX element's scalar CGRect result; perform would use the wrong ABI.
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

    static func findViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(findViews) }

    static func accessibilityTree(_ view: NSView?) -> [AXObservation] {
        guard let view else { return [] }
        var result = [AXObservation]()
        for object in accessibilityObjects(view) {
            let role = object.accessibilityObjectValue("accessibilityRole")
            let label = object.accessibilityObjectValue("accessibilityLabel")
            let value = object.accessibilityObjectValue("accessibilityValue")
            let actions = object.accessibilityObjectValues("accessibilityActionNames")
            guard role != nil || label != nil || value != nil || !actions.isEmpty else { continue }
            result.append(AXObservation(
                role: role,
                label: label,
                value: value,
                actions: actions,
                childCount: object.accessibilityChildrenCount
            ))
        }
        return result
    }

    static func accessibilityObjects(_ view: NSView) -> [NSObject] {
        var result = [NSObject]()
        for subview in view.subviews { result += accessibilityObjects(subview) }
        result += accessibilityObjects(view as NSObject)
        return result
    }

    static func accessibilityObjects(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [Any]
        else { return result }
        for child in children {
            if let child = child as? NSObject { result += accessibilityObjects(child) }
        }
        return result
    }
}

extension NSObject {
    var accessibilityChildrenCount: Int {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard responds(to: selector), let value = perform(selector)?.takeUnretainedValue() as? [Any] else { return 0 }
        return value.count
    }

    func accessibilityObjectValue(_ name: String) -> String? {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector), let value = perform(selector)?.takeUnretainedValue() else { return nil }
        return String(describing: value)
    }

    func accessibilityObjectValues(_ name: String) -> [String] {
        let selector = NSSelectorFromString(name)
        guard responds(to: selector), let values = perform(selector)?.takeUnretainedValue() as? [Any] else { return [] }
        return values.map(String.init(describing:))
    }
}

@MainActor final class TwoRowOutlineDataSource: NSObject, NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 2 : 0
    }

    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool { false }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any { index }
}

extension String {
    var matchesDynamicClock: Bool {
        let scalar = split(separator: ":")
        if scalar.count == 2, scalar.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }
        let suffix = last.map(String.init) ?? ""
        return ["m", "h", "d"].contains(suffix) && dropLast().allSatisfy(\.isNumber)
    }
}
