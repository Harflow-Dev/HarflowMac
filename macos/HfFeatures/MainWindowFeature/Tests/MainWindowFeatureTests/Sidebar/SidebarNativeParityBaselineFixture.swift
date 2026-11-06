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
    let promptViewModel: NewSessionViewModelMock
    let promptEditor: NSTextView
    let outline: NSOutlineView
    let anchorRow: Int
    let groupRow: Int
    let workflowAliasRow: Int
    let shortcutAliasRow: Int
    private let previousEnhancedInterface: Any?
    private let previousActivationPolicy: NSApplication.ActivationPolicy

    /// The unified surface's exact entry order: five navigation rows, the Running section, its
    /// travelled Recent work, and the admission sentinel. Discovery is ID-based — the single
    /// outline that owns the `navigation:new-task` entry.
    static let unifiedEntryIDs = [
        "navigation:new-task", "navigation:needs-you", "navigation:workflows", "navigation:resources",
        "navigation:statistics", "header:running", "task:abc123", "task:abc123-child", "group:review-bot",
        "header:recent", "task:def456", "workflow:baseline-workflow",
        "workflow-shortcut:baseline-parent:baseline-workflow", "task:ghi789", "history:sentinel"
    ]

    /// Every outline under `view` that realizes the unified navigation entry.
    static func unifiedOutlines(in view: NSView) -> [NSOutlineView] {
        findViews(view).compactMap { $0 as? NSOutlineView }.filter { outline in
            (0 ..< outline.numberOfRows).contains {
                (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == "navigation:new-task"
            }
        }
    }

    /// The single unified outline, `nil` while reconciliation has not settled it (or on duplication).
    static func unifiedOutline(in view: NSView) -> NSOutlineView? {
        let outlines = unifiedOutlines(in: view)
        return outlines.count == 1 ? outlines[0] : nil
    }

    static func entryIDs(in outline: NSOutlineView) -> [String] {
        (0 ..< outline.numberOfRows).compactMap { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id }
    }

    /// The outline row realizing one unified entry id.
    static func row(of entryID: String, in outline: NSOutlineView) -> Int? {
        (0 ..< outline.numberOfRows).first {
            (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == entryID
        }
    }

    /// The shared navigation block's row geometry in window space: the union of every navigation
    /// row's native rect, independent of the obsolete AX-button frame lookup.
    static func navigationFrame(of outline: NSOutlineView) -> CGRect? {
        var frame: CGRect?
        for index in 0 ..< outline.numberOfRows
        where (outline.item(atRow: index) as? SidebarNativeItemBox)?.entry.id.hasPrefix("navigation:") == true {
            let rect = outline.convert(outline.rect(ofRow: index), to: nil)
            frame = frame.map { $0.union(rect) } ?? rect
        }
        return frame
    }

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
            guard let outline = Self.unifiedOutline(in: hostedView), Self.entryIDs(in: outline).count == 15 else { return false }
            return NSApp.isActive && hostedWindow.isKeyWindow
                && Self.entryIDs(in: outline) == Self.unifiedEntryIDs
                && Self.findViews(hostedView).compactMap { $0 as? ComposerPromptScrollView }.count == 1
        }
        Self.writeUnifiedDiagnostic(hostedView: hostedView, hostedWindow: hostedWindow)
        let foundOutline = try #require(Self.unifiedOutline(in: hostedView))
        self.outline = foundOutline
        // ID-based row resolution: every probe anchors on an entry id, never a subview order.
        self.anchorRow = try #require(Self.row(of: "task:def456", in: foundOutline))
        self.groupRow = try #require(Self.row(of: "group:review-bot", in: foundOutline))
        self.workflowAliasRow = try #require(Self.row(of: "workflow:baseline-workflow", in: foundOutline))
        self.shortcutAliasRow = try #require(Self.row(of: "workflow-shortcut:baseline-parent:baseline-workflow", in: foundOutline))
        let promptScrollViews = Self.findViews(hostedView).compactMap { $0 as? ComposerPromptScrollView }
        try #require(promptScrollViews.count == 1)
        self.promptEditor = try #require(promptScrollViews.first?.promptTextView)
        try #require(promptEditor.isEditable && promptEditor.window === hostedWindow)
        #expect(!Self.findViews(hostedView).compactMap { $0 as? NSTextField }.contains { $0.placeholderString == "Search loaded history" })
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
                fittingHeight: Self.contentFittingHeight(of: rowView, row: row),
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
            navigationFrame: Self.navigationFrame(of: outline).map(FrameRecord.init) ?? FrameRecord(.zero),
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
        await waitUntil(timeout: 5) {
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            guard let coordinator = outline.delegate as? SidebarNativeList.Coordinator else { return false }
            return coordinator.reconciliation == nil && coordinator.detached == nil
                && coordinator.pendingInput == nil && !coordinator.hasUnsettledPresentations
                && coordinator.pendingHeights.isEmpty && coordinator.pendingHostedHeights.isEmpty
                && coordinator.settledGeneration == coordinator.generation
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

    /// The native `NSTableCellView` wrapper has no intrinsic content size (its fit reports 0);
    /// the production hosted cell's own `NSHostingView` fit is the real row content height, proven
    /// by the hosted layout tests. A row without its hosted content is recorded and fails loudly —
    /// never a silent zero that could pass as an empty measurement.
    private static func contentFittingHeight(of rowView: NSView?, row: Int) -> CGFloat {
        guard rowView != nil else {
            Issue.record("Unified baseline row \(row) has no realized native cell to measure")
            return 0
        }
        guard let cell = rowView as? SidebarNativeCell else { return rowView?.fittingSize.height ?? 0 }
        guard let host = cell.host else {
            Issue.record("Unified baseline row \(row) has a native cell without its hosted content")
            return 0
        }
        return host.fittingSize.height
    }

    private func send(_ probe: KeyboardProbe) -> KeyboardObservation {
        outline.window?.makeFirstResponder(outline)
        let anchor = Self.row(of: probe.anchorEntryID, in: outline) ?? anchorRow
        outline.selectRowIndexes(IndexSet(integer: anchor), byExtendingSelection: false)
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
        // Seed the unified outline's anchor row after the keyboard probes and before alias selection.
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet(integer: anchorRow), byExtendingSelection: false)
        let selectionBefore = Array(outline.selectedRowIndexes)
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
            selectionBefore: selectionBefore,
            selectionAfter: Array(outline.selectedRowIndexes)
        )
    }

    private func aliasSelection() -> [Int] {
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet([workflowAliasRow, shortcutAliasRow]), byExtendingSelection: false)
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
    let selectionBefore: [Int]
    let selectionAfter: [Int]
}

// MARK: - Native helpers

extension SidebarNativeBaselineFixture {
    static func findViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(findViews) }

    private static func accessibilityFrameInWindow(_ object: NSObject, window: NSWindow) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol {
            return window.convertFromScreen(accessible.accessibilityFrame())
        }
        // KVC boxes a virtual AX element's scalar CGRect result; perform would use the wrong ABI.
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

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

// MARK: - Unified AX diagnostic (test-only)

/// Env-gated, diagnostic-only AX/geometry snapshot of the unified surface before the strict `#require`.
private extension SidebarNativeBaselineFixture {
    static func writeUnifiedDiagnostic(hostedView: NSView, hostedWindow: NSWindow) {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_SIDEBAR_NATIVE_BASELINE_OUTPUT"] else { return }
        let base = output as NSString
        let name = base.deletingPathExtension + "-unified-diagnostic." + (base.pathExtension.isEmpty ? "json" : base.pathExtension)
        do {
            let data = try JSONSerialization.data(withJSONObject: unifiedPayload(hostedView: hostedView, hostedWindow: hostedWindow),
                                                   options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: name), options: .atomic)
        } catch {
            Issue.record("Unified sidebar diagnostic failed at \(name): \(error)")
        }
    }

    private static func unifiedPayload(hostedView: NSView, hostedWindow: NSWindow) -> [String: Any] {
        let outlines = findViews(hostedView).compactMap { $0 as? NSOutlineView }.filter { outline in
            (0 ..< outline.numberOfRows).contains { (outline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == "navigation:new-task" }
        }
        return [
            "window": ["frame": frameRecord(hostedWindow.frame), "contentLayoutRect": frameRecord(hostedWindow.contentLayoutRect)],
            "unifiedOutlines": outlines.map { outlineRecord($0, window: hostedWindow) },
            "chromeAX": chromeAX(hostedView, window: hostedWindow)
        ]
    }

    private static func chromeAX(_ view: NSView, window: NSWindow) -> [[String: Any]] {
        accessibilityObjects(view)
.filter { object in
            ["sidebar-unified", "sidebar-navigation-New task"].contains(object.accessibilityObjectValue("accessibilityIdentifier") ?? "")
                || ["Collapse sidebar", "Settings", "New task"].contains(object.accessibilityObjectValue("accessibilityLabel") ?? "")
        }
.map { axRecord($0, window: window) }
    }

    private static func outlineRecord(_ outline: NSOutlineView, window: NSWindow) -> [String: Any] {
        let selector = NSSelectorFromString("accessibilityRows")
        let rows = outline.responds(to: selector)
            ? (outline.value(forKey: "accessibilityRows") as? [Any])?.compactMap { $0 as? NSObject } ?? [] : []
        let entries = (0 ..< outline.numberOfRows).map { row -> [String: Any] in
            let box = outline.item(atRow: row) as? SidebarNativeItemBox
            let view = outline.view(atColumn: 0, row: row, makeIfNecessary: false)
            return [
                "index": row,
                "entryID": box?.entry.id ?? NSNull(),
                "destination": box?.entry.destination.map(\.pathId) ?? NSNull(),
                "displayID": box.map { String(describing: $0.entry.displayID) } ?? NSNull(),
                "rect": frameRecord(outline.rect(ofRow: row)),
                "fittingHeight": view?.fittingSize.height ?? 0,
                "cellAX": accessibilityTree(view).map { observation in
                    ["role": observation.role ?? NSNull(), "label": observation.label ?? NSNull(), "value": observation.value ?? NSNull(),
                     "actions": observation.actions, "childCount": observation.childCount] as [String: Any]
                }
            ]
        }
        let scroll = outline.enclosingScrollView
        return [
            "rowCount": outline.numberOfRows,
            "scrollBounds": frameRecord(scroll?.bounds ?? .zero),
            "scrollFrameInWindow": frameRecord(scroll.map { $0.convert($0.bounds, to: nil) } ?? .zero),
            "outlineEntries": entries,
            "axRowsCount": rows.count,
            "axRows": rows.map { axRecord($0, window: window) },
            "axTree": accessibilityObjects(outline).map { axRecord($0, window: window) }
        ]
    }

    private static func axRecord(_ object: NSObject, window: NSWindow) -> [String: Any] {
        let selected = object.responds(to: NSSelectorFromString("isAccessibilitySelected")) ? object.value(forKey: "accessibilitySelected") as? NSNumber : nil
        var record: [String: Any] = Dictionary(uniqueKeysWithValues: ["Role", "Label", "Title", "Identifier", "Value", "Help", "Description"].map {
            ($0.lowercased(), (object.accessibilityObjectValue("accessibility\($0)") as Any?) ?? NSNull())
        })
        record["actions"] = object.accessibilityObjectValues("accessibilityActionNames")
        record["selected"] = selected?.boolValue ?? NSNull()
        record["supportsSetAccessibilitySelected"] = object.responds(to: NSSelectorFromString("setAccessibilitySelected:"))
        record["supportsAccessibilityPerformPress"] = object.responds(to: NSSelectorFromString("accessibilityPerformPress"))
        record["frameInWindow"] = accessibilityFrameInWindow(object, window: window).map(frameRecord) ?? NSNull()
        return record
    }

    private static func frameRecord(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.maxX, rect.maxY] }
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

extension String {
    var matchesDynamicClock: Bool {
        let scalar = split(separator: ":")
        if scalar.count == 2, scalar.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }
        let suffix = last.map(String.init) ?? ""
        return ["m", "h", "d"].contains(suffix) && dropLast().allSatisfy(\.isNumber)
    }
}
