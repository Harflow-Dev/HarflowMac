//
// SidebarNativeParityBaselineTests.swift
// MainWindowFeatureTests
//
// This is the recorded native List baseline for the sidebar adapter.  The first run writes a
// machine-readable observation outside the repository.  Once that observation has been reviewed,
// the stable fields are copied into the expectations below; the test then remains useful when the
// List renderer is replaced by the owned NSOutlineView renderer.
//

import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbCommon
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor
@Suite(.serialized) struct SidebarNativeParityBaselineTests {
    @Test func givenTheCurrentSidebarList_whenHosted_thenRecordNativeParityBaseline() async throws {
        // given — explicit local rows cover each current sidebar presentation kind in a real
        // window; no backend or persisted task data is used.
        let fixture = try await SidebarNativeBaselineFixture()
        defer { fixture.close() }

        // when — let native fitting and disclosure layout settle, then observe public behavior.
        await fixture.settle()
        let baseline = fixture.observe()
        fixture.write(baseline)

        // then — missing public accessibility is a baseline issue, never an empty pass.
        // A missing native accessibility surface is an issue to resolve, not an empty successful
        // baseline.  Keep the observed names in the report so the failure is actionable.
        #expect(!baseline.rows.isEmpty, "The native sidebar baseline must contain rows")
        #expect(baseline.rows.allSatisfy { !$0.accessibility.isEmpty },
                "Every baseline row must expose an accessibility element")
        #expect(baseline.missingAccessibility.isEmpty,
                "Native sidebar AX baseline is incomplete: \(baseline.missingAccessibility)")

        // Stable public control settings and semantic row behavior are pinned below. The external
        // JSON is diagnostic evidence only; CI does not depend on it.
        #expect(baseline.flags.indentationPerLevel >= 0)
        #expect(baseline.rows.allSatisfy { $0.rect.width >= 0 && $0.rect.height >= 0 })
        #expect(baseline.keyboard.count == KeyboardProbe.allCases.count)
        #expect(baseline.searchFocus.requestedFirstResponder)
        #expect(baseline.searchFocus.arrowsKeptFocus)
        #expect(baseline.aliasSelection == [8, 9])

        // Reviewed native List baseline (captured on the current macOS SDK).  These are public
        // control settings and semantic row geometry, not object addresses or SwiftUI internals.
        #expect(baseline.flags.allowsTypeSelect)
        #expect(!baseline.flags.floatsGroupRows)
        #expect(baseline.flags.indentationPerLevel == 12)
        #expect(!baseline.flags.allowsMultipleSelection)
        #expect(baseline.flags.allowsEmptySelection)
        #expect(!baseline.flags.refusesFirstResponder)
        #expect(baseline.flags.selectionHighlightStyle == 1)
        #expect(baseline.flags.rowSizeStyle == 2)
        #expect(baseline.flags.style == 3)
        // Record the production-context inset for comparison, but do not make the adapter copy the
        // legacy List's private footer accounting. B5 requires the owned native scroll view to use
        // zero contentInsets while the surrounding footer remains outside that surface.
        #expect(baseline.flags.contentInsets.top == 0)
        #expect(baseline.flags.contentInsets.left == 0)
        #expect(baseline.flags.contentInsets.right == 0)
        #expect(baseline.flags.contentInsets.bottom >= 0)
        #expect(baseline.rows.allSatisfy { $0.rect.width > 0 })
        #expect(baseline.searchFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
        #expect(baseline.scrollFrame.minY >= baseline.contentLayoutRect.minY - 1)
        #expect(baseline.scrollFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
        #expect(baseline.effectiveViewportBottom == 49)
        #expect(baseline.effectiveViewportTop == 666)
        #expect(baseline.firstRowFrame.minY >= baseline.effectiveViewportBottom - 1)
        #expect(baseline.firstRowFrame.maxY <= baseline.searchFrame.minY)
        #expect(zip(baseline.rows, baseline.rows.dropFirst()).allSatisfy { current, next in
            next.rect.minY >= current.rect.maxY
        })
        let contentRows = baseline.rows.enumerated().filter { ![0, 2, 6, 10, 12].contains($0.offset) }
        #expect(contentRows.allSatisfy { $0.element.rect.height >= $0.element.fittingHeight - 1 })
        #expect(baseline.rows.map(\.stableAXSignature) == expectedAXSignatures)
        for probe in KeyboardProbe.allCases {
            let result = try #require(baseline.keyboard[probe.rawValue])
            #expect(result.selectedRowsBefore == [3])
            #expect(result.firstResponder)
            #expect(result.selectedRowsAfter == expectedKeyboardSelection[probe])
        }
    }

    @Test func givenPlainOwnedOutline_whenMultipleSelectionIsDisabled_thenProgrammaticAliasesRemainSelectable() {
        // given — the public AppKit outline API with the same single-logical-selection flag used
        // by the sidebar adapter.
        let outline = NSOutlineView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let dataSource = TwoRowOutlineDataSource()
        outline.dataSource = dataSource
        outline.allowsMultipleSelection = false
        outline.reloadData()

        // when — synchronize two rows representing one logical destination.
        outline.selectRowIndexes(IndexSet([0, 1]), byExtendingSelection: false)

        // then — AppKit retains both programmatic alias indices while user multi-selection stays
        // disabled.
        #expect(Array(outline.selectedRowIndexes) == [0, 1])
    }
}

// MARK: - Fixture

@MainActor private final class SidebarNativeBaselineFixture {
    let viewModel: SidebarViewModelMock
    let controller: NSHostingController<AnyView>
    let window: NSWindow
    let search: NSTextField
    let outline: NSOutlineView
    private let previousEnhancedInterface: Any?

    init() async throws {
        _ = NSApplication.shared
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        let rows = SidebarViewModelMock.defaultSections.map { section -> SidebarSection in
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
        self.viewModel = SidebarViewModelMock(
            sections: rows
        )
        viewModel.savedWorkflows = [WorkflowRecord(raw: ["name": .string("baseline-definition")])]
        let model = viewModel
        let root = AnyView(NavigationSplitView {
            SidebarView(model).navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 340)
        } detail: {
            Text("Detail")
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
        window.orderFront(nil)
        let hostedView = controller.view
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return Self.findSearch(in: hostedView) != nil
                && (Self.findOutline(in: hostedView)?.numberOfRows ?? 0) > 0
        }
        let foundSearch = try #require(Self.findSearch(in: hostedView))
        let foundOutline = try #require(Self.findOutline(in: hostedView))
        self.search = foundSearch
        self.outline = foundOutline
        await waitUntil(timeout: 5) {
            hostedView.layoutSubtreeIfNeeded()
            return foundOutline.numberOfRows >= 5
        }
    }

    func close() {
        window.contentView = nil
        window.close()
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
        let searchFocus = probeSearchFocus()
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
            searchFocus: searchFocus,
            aliasSelection: aliasSelection(),
            searchFrame: FrameRecord(search.convert(search.bounds, to: nil)),
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
        guard let path = ProcessInfo.processInfo.environment["PB_SIDEBAR_NATIVE_BASELINE_OUTPUT"] else { return }
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
        outline.selectRowIndexes(IndexSet(integer: 3), byExtendingSelection: false)
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

    private func probeSearchFocus() -> SearchFocusObservation {
        let requested = search.window?.makeFirstResponder(search) ?? false
        let fieldEditor = search.window?.firstResponder as? NSTextView
        let before = Array(outline.selectedRowIndexes)
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil,
            characters: String(UnicodeScalar(0xF700)!),
            charactersIgnoringModifiers: String(UnicodeScalar(0xF700)!), isARepeat: false, keyCode: 126
        )
        if let event, let responder = search.window?.firstResponder as? NSResponder { responder.keyDown(with: event) }
        return SearchFocusObservation(
            requestedFirstResponder: requested,
            arrowsKeptFocus: fieldEditor != nil && search.window?.firstResponder === fieldEditor
                && fieldEditor?.delegate === search,
            firstResponderClass: search.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil",
            selectionBefore: before,
            selectionAfter: Array(outline.selectedRowIndexes)
        )
    }

    private func aliasSelection() -> [Int] {
        outline.window?.makeFirstResponder(outline)
        outline.selectRowIndexes(IndexSet([8, 9]), byExtendingSelection: false)
        return Array(outline.selectedRowIndexes)
    }
}

// MARK: - Recorded values

private struct Baseline: Codable {
    let flags: Flags
    let rows: [RowObservation]
    let missingAccessibility: [Int]
    let keyboard: [String: KeyboardObservation]
    let searchFocus: SearchFocusObservation
    let aliasSelection: [Int]
    let searchFrame: FrameRecord
    let scrollFrame: FrameRecord
    let firstRowFrame: FrameRecord
    let effectiveViewportBottom: CGFloat
    let effectiveViewportTop: CGFloat
    let contentLayoutRect: FrameRecord
}

private struct FrameRecord: Codable {
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

private struct Flags: Codable {
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

private struct EdgeInsetsRecord: Codable, Equatable {
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

private struct RowObservation: Codable {
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

private struct AXObservation: Codable {
    let role: String?
    let label: String?
    let value: String?
    let actions: [String]
    let childCount: Int
}

private struct KeyboardObservation: Codable {
    let selectedRowsBefore: [Int]
    let selectedRowsAfter: [Int]
    let firstResponder: Bool
    let represented: Bool
}

private struct SearchFocusObservation: Codable {
    let requestedFirstResponder: Bool
    let arrowsKeptFocus: Bool
    let firstResponderClass: String
    let selectionBefore: [Int]
    let selectionAfter: [Int]
}

private enum KeyboardProbe: String, CaseIterable, Hashable {
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

private extension SidebarNativeBaselineFixture {
    static func findSearch(in view: NSView) -> NSTextField? {
        ([view] + view.subviews.flatMap { findViews($0) })
.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Search loaded history" }
    }

    static func findOutline(in view: NSView) -> NSOutlineView? {
        ([view] + view.subviews.flatMap { findViews($0) }).compactMap { $0 as? NSOutlineView }.first
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

private extension NSObject {
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

@MainActor private final class TwoRowOutlineDataSource: NSObject, NSOutlineViewDataSource {
    func outlineView(_: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? 2 : 0
    }

    func outlineView(_: NSOutlineView, isItemExpandable _: Any) -> Bool { false }

    func outlineView(_: NSOutlineView, child index: Int, ofItem _: Any?) -> Any { index }
}

private extension String {
    var matchesDynamicClock: Bool {
        let scalar = split(separator: ":")
        if scalar.count == 2, scalar.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return true }
        let suffix = last.map(String.init) ?? ""
        return ["m", "h", "d"].contains(suffix) && dropLast().allSatisfy(\.isNumber)
    }
}

private let expectedAXSignatures: [[String]] = [
    // The native header keeps both existing actions reachable while exposing its semantic heading.
    ["AXButton|Collapse workflows||", "AXButton|New workflow||", "AXHeading|Collapse workflows||"],
    ["AXStaticText||baseline-definition|"],
    ["AXHeading|Running||"],
    ["AXStaticText||Fix the login bug|", "AXUnknown|Running||", "AXButton|Collapse Fix the login bug|Expanded|",
     "AXStaticText||Claude · repo · 1 sub-task|"],
    ["AXStaticText||Write the migration|", "AXUnknown|Running||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||review-bot|", "AXUnknown|Claude, Codex||", "AXStaticText||Parallel run · 1 of 2 finished|",
     "AXUnknown|Running||", "AXButton|Expand or collapse review-bot|Collapsed|"],
    ["AXHeading|Today||"],
    ["AXStaticText||Refactor the parser|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline workflow|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline shortcut|", "AXUnknown|Failed||", "AXStaticText||Child workflow|",
     "AXStaticText||Vibe · repo|"],
    ["AXHeading|Earlier||"],
    ["AXStaticText||Bump dependencies|", "AXUnknown|Failed||", "AXStaticText||Vibe · app|"],
    []
]

private let expectedKeyboardSelection: [KeyboardProbe: [Int]] = [
    .up: [1], .down: [4], .home: [3], .end: [3], .pageUp: [3], .pageDown: [3],
    .commandA: [3], .return: [3], .space: [3], .letter: [3]
]
