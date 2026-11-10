//
//  TopBarIntegratedFixture+Toolbar.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI

// MARK: - Toolbar inspection

/// Reads the real `NSToolbar`: its item objects, which of them are visible (not in the overflow menu) and where, and the
/// accessibility tree inside each item's view. All frames are in screen coordinates.
extension TopBarIntegratedFixture {

    static let more = "task-detail.more"
    static let inspector = "task-detail.inspector"
    static let takeover = "task-detail.takeover"

    var items: [NSToolbarItem] { window.toolbar?.items ?? [] }
    var itemIdentifiers: [String] { items.map(\.itemIdentifier.rawValue) }

    func item(_ identifier: String) -> NSToolbarItem? {
        items.first { $0.itemIdentifier.rawValue == identifier }
    }

    /// The item that carries the principal content: the one whose view draws the scenario's title, else the toolbar's
    /// centered item.
    var principalItem: NSToolbarItem? {
        if let byTitle = items.first(where: { $0.view.map { element(labelled: config.title, in: $0) != nil } ?? false }) {
            return byTitle
        }
        guard let toolbar = window.toolbar else { return nil }
        return items.first { toolbar.centeredItemIdentifiers.contains($0.itemIdentifier) && $0.view != nil }
    }

    /// Items AppKit currently draws in the bar, as opposed to the overflow menu.
    func isInBar(_ item: NSToolbarItem?) -> Bool {
        guard let item, let visible = window.toolbar?.visibleItems else { return false }
        return visible.contains { $0 === item }
    }

    func screenFrame(of item: NSToolbarItem?) -> CGRect? {
        guard let view = item?.view, view.window === window else { return nil }
        return window.convertToScreen(view.convert(view.bounds, to: nil))
    }

    /// Whether the item is in the bar and its view has a positive frame inside the window.
    func isOnScreen(_ item: NSToolbarItem?) -> Bool {
        guard isInBar(item), let frame = screenFrame(of: item), let view = item?.view else { return false }
        return frame.width > 0 && frame.height > 0 && !view.isHiddenOrHasHiddenAncestor
            && window.frame.insetBy(dx: -1, dy: -1).contains(frame)
    }

    // MARK: Accessibility tree

    /// `root` and everything reachable through accessibility children and subviews.
    func elements(in root: NSObject) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [root]
        while let next = queue.popLast(), result.count < 6000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            result.append(next)
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] {
                queue.append(contentsOf: kids)
            }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return result
    }

    func string(_ object: NSObject, _ property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    func label(_ object: NSObject) -> String? { string(object, "accessibilityLabel") }

    func strings(in root: NSObject) -> [String] {
        elements(in: root).flatMap { [label($0), string($0, "accessibilityValue")].compactMap(\.self) }.filter { !$0.isEmpty }
    }

    /// The toolbar item whose view renders an element labelled `text`, for items that carry no identifier of ours.
    func itemRendering(_ text: String) -> NSToolbarItem? {
        items.first { item in item.view.map { element(labelled: text, in: $0) != nil } ?? false }
    }

    /// The first element of `root` whose label or value equals `text`.
    func element(labelled text: String, in item: NSToolbarItem) -> NSObject? {
        item.view.flatMap { element(labelled: text, in: $0) }
    }

    func element(labelled text: String, in root: NSObject) -> NSObject? {
        elements(in: root).first { matches($0, text) }
    }

    /// Whether the element's accessibility label, value or title equals `text` exactly. SwiftUI exposes the same text through
    /// any of the three depending on the control, so lookups that must not miss a rendered string use all of them.
    func matches(_ object: NSObject, _ text: String) -> Bool {
        label(object) == text || string(object, "accessibilityValue") == text || string(object, "accessibilityTitle") == text
    }

    /// The screen frame an accessibility element reports.
    func screenFrame(ofElement object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue else { return nil }
        return value.rectValue
    }

    // MARK: The window's own accessibility tree

    /// Every accessibility element of the window's content, for the pane and its facts groups.
    var contentElements: [NSObject] { window.contentView.map { elements(in: $0) } ?? [] }

    func contentElement(labelled text: String) -> NSObject? { contentElements.first { label($0) == text } }

    /// The first element of the window's content whose label, value or title equals `text` exactly.
    func contentText(_ text: String) -> NSObject? { contentElements.first { matches($0, text) } }

    /// Every distinct label, value and title in the window's content, for a failure message.
    var contentStrings: [String] {
        let all = contentElements.flatMap { [label($0), string($0, "accessibilityValue"), string($0, "accessibilityTitle")].compactMap(\.self) }
        return Array(Set(all.filter { !$0.isEmpty })).sorted()
    }

    /// A facts group's header: an element whose value is Expanded or Collapsed and whose label starts with `title`.
    func groupHeader(_ title: String) -> NSObject? {
        contentElements.first {
            let value = string($0, "accessibilityValue")
            return (value == "Expanded" || value == "Collapsed") && label($0)?.hasPrefix(title) == true
        }
    }

    /// The labels of every facts group header currently drawn, for a failure message.
    var groupHeaderLabels: [String] {
        contentElements.compactMap { element in
            let value = string(element, "accessibilityValue")
            return value == "Expanded" || value == "Collapsed" ? label(element) : nil
        }
    }

    /// Whether the window's first responder is a view whose frame lies inside the pane's frame.
    var firstResponderIsInsidePane: Bool {
        guard let pane = contentElement(labelled: "Task details").flatMap({ screenFrame(ofElement: $0) }),
              let view = window.firstResponder as? NSView, view.window === window else { return false }
        return pane.insetBy(dx: -1, dy: -1).contains(window.convertToScreen(view.convert(view.bounds, to: nil)))
    }

    func groupValue(_ title: String) -> String? { groupHeader(title).flatMap { string($0, "accessibilityValue") } }

    var hasPane: Bool { contentElement(labelled: "Task details") != nil }

    /// The label of the element the application reports as focused.
    var focusedLabel: String? {
        let focused = NSApp.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXFocusedUIElement")) as? NSObject
        return focused.flatMap { label($0) }
    }

    /// Keeps the fixture's application and window active, as the other capture suites do while they wait.
    func keepActive() {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !window.isKeyWindow { window.makeKey() }
    }
}

// MARK: - Expected items

/// One toolbar control a scenario must render.
struct TopBarExpectedItem {
    let name: String
    /// The item's identifier when it has one of ours; `nil` finds it by its rendered label.
    let identifier: String?
    /// The accessibility label the rendered control carries.
    let label: String
}

extension TopBarIntegratedFixture {

    /// Everything the scenario must draw: More actions, the chips in `chips`, and the resource return when offered. The
    /// labels come from the product's own chip rules applied to `content`, but whether each control exists is decided
    /// only by what the toolbar renders, never by the published content.
    func expectedItems(chips: [TopBarChip], content: TaskTopBarContent) -> [TopBarExpectedItem] {
        var result = [TopBarExpectedItem(name: "More actions", identifier: Self.more, label: "More actions")]
        result += chips.map { TopBarExpectedItem(name: $0.header + " chip", identifier: $0.identifier, label: $0.label(for: content)) }
        if config.resourceReturn {
            result.append(TopBarExpectedItem(name: "Back to resource slots", identifier: nil, label: "Back to resource slots"))
        }
        return result
    }

    /// The rendered toolbar item for an expectation, `nil` when nothing renders its label.
    func renderedItem(_ expected: TopBarExpectedItem) -> NSToolbarItem? {
        let candidate = expected.identifier.flatMap(item) ?? itemRendering(expected.label)
        guard let candidate, element(labelled: expected.label, in: candidate) != nil else { return nil }
        return candidate
    }

    /// Why an expected control is not drawn: absent, labelled differently, in the overflow menu, or without a positive frame.
    func problems(with expected: [TopBarExpectedItem]) -> [String] {
        expected.compactMap { entry -> String? in
            guard let rendered = renderedItem(entry) else { return "\(entry.name) is not rendered (label \(entry.label))" }
            return isOnScreen(rendered) ? nil : "\(entry.name) is not visible in the bar with a positive on-screen frame"
        }
    }

    /// Whether a toolbar item or element anywhere in the toolbar renders `text`.
    func toolbarRenders(_ text: String) -> Bool { itemRendering(text) != nil }

    // MARK: Inline resource card

    /// The inline card's title element in the window content, `nil` while it is not drawn.
    func resourceCardTitle(_ title: String) -> NSObject? { contentText(title) }

    /// The screen frame of the activity transcript's scroll view, `nil` when no feed is mounted.
    var transcriptFrame: CGRect? {
        guard let content = window.contentView,
              let scroll = ActivityFeedTranscriptStyleHostedTests.tables(content).first?.enclosingScrollView else { return nil }
        return window.convertToScreen(scroll.convert(scroll.bounds, to: nil))
    }
}
