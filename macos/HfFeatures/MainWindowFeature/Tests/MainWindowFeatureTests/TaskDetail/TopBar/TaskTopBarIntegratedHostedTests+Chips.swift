//
//  TaskTopBarIntegratedHostedTests+Chips.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - Chip

/// One of the toolbar's three trailing chips and the Events facts group it reveals.
enum TopBarChip: CaseIterable, CustomTestStringConvertible, Sendable {
    case continuity, notices, access

    var identifier: String {
        switch self {
        case .continuity: "task-detail.chip.continuity"
        case .notices: "task-detail.chip.notices"
        case .access: "task-detail.chip.access"
        }
    }

    var group: TaskPaneStateStore.FactsGroup {
        switch self {
        case .continuity: .continuity
        case .notices: .notices
        case .access: .enforcement
        }
    }

    /// The facts group header's title.
    var header: String {
        switch self {
        case .continuity: "Continuity"
        case .notices: "Notices"
        case .access: "What was enforced"
        }
    }

    /// The chip's accessibility label for the published content.
    func label(for content: TaskTopBarContent) -> String {
        let chips = content.chips(isNarrow: false)
        switch self {
        case .continuity: return TaskTopBarChips.continuityLabel
        case .notices: return chips.noticesLabel
        case .access: return chips.accessLabel
        }
    }

    var testDescription: String { header }
}

// MARK: - Focus return

/// Where focus went after the revealed pane closed.
enum TopBarFocusReturn: String {
    /// Keyboard focus is on the chip's own view.
    case keyboard
    /// The accessibility cursor is on the chip and the keyboard fell back to the window.
    case accessibility
}

extension TopBarIntegratedFixture {
    /// One line of focus evidence for a diagnostic print; it asserts nothing. It shows the responder chain, whether the chip's
    /// own view and its descendants accept first responder, and what the application reports as accessibility-focused.
    func focusDiagnostics(item: NSToolbarItem, stage: String) -> String {
        var chain: [String] = []
        var responder: NSResponder? = window.firstResponder
        while let next = responder, chain.count < 8 {
            chain.append(String(describing: type(of: next)))
            responder = next.nextResponder
        }
        let chipViews = item.view.map { view in ([view] + elements(in: view).compactMap { $0 as? NSView }) } ?? []
        let accepting = chipViews.filter(\.acceptsFirstResponder).map { String(describing: type(of: $0)) }
        return "TOPBAR focus [\(stage)] responder chain \(chain); window is first responder \(window.firstResponder === window); "
            + "chip view \(item.view.map { String(describing: type(of: $0)) } ?? "none") in window \(item.view?.window === window), "
            + "accepting views \(accepting); accessibility focus \(String(describing: focusedLabel)); key window \(window.isKeyWindow)"
    }

    /// The observable focus state for `item`, `nil` while neither route has landed. Clearing the controller's pending request
    /// is not evidence: this reads the window's first responder and the application's accessibility focus.
    ///
    /// The keyboard fallback is the window itself, which is what AppKit makes first responder when nothing in the window
    /// accepts focus. Any other view holding focus (the composer's field editor, the transcript, a facts group) is not a
    /// return to the chip and is not accepted: the accessibility route needs the window as first responder *and* the
    /// cursor on the chip.
    func focusReturn(to item: NSToolbarItem, label: String) -> TopBarFocusReturn? {
        if let view = item.view, let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) {
            return .keyboard
        }
        if window.firstResponder === window, focusedLabel == label { return .accessibility }
        return nil
    }
}

// MARK: - Interaction

extension TaskTopBarIntegratedHostedTests {

    @Test(arguments: TopBarChip.allCases)
    func givenARenderedChip_whenPressedAndItsPaneIsClosedFromThePane_thenTheFactsGroupOpensAndFocusReturnsToTheChipOrTheWindow(
        chip: TopBarChip
    ) async throws {
        // given the chips in a wide window, none of them overflowed
        let fixture = await Fixture(.init(width: 1600, title: Fixture.TitleKind.medium.text, enforcementSnapshot: chip == .access,
                                          resourceReturn: true))
        defer { fixture.close() }
        fixture.keepActive()
        let content = try #require(fixture.content, "the task never published its top bar content")
        let label = chip.label(for: content)
        await waitUntil(timeout: 8) {
            fixture.keepActive()
            fixture.pump()
            return fixture.item(chip.identifier).flatMap { item in fixture.element(labelled: label, in: item) } != nil
        }
        let item = try #require(fixture.item(chip.identifier), "no \(chip.identifier); items \(fixture.itemIdentifiers)")
        let button = try #require(fixture.element(labelled: label, in: item), "no control labelled \(label): \(item.view.map(fixture.strings(in:)) ?? [])")
        #expect(fixture.isOnScreen(item), "the chip is not drawn in the bar")
        #expect(!fixture.hasPane)
        // the return must be a change this test causes: before the press, focus is not already on the chip either way
        #expect(fixture.focusReturn(to: item, label: label) == nil, "focus was already on the chip before it was pressed")

        print(fixture.focusDiagnostics(item: item, stage: "\(chip.header) before press"))

        // when the actual rendered chip is pressed
        #expect(M04ToolbarEvidence.press(button), "\(label) did not accept a press")
        await waitUntil(timeout: 8) {
            fixture.keepActive()
            fixture.pump()
            fixture.publish()
            return fixture.hasPane && fixture.groupValue(chip.header) == "Expanded"
        }

        // then the pane is open on Events with that group expanded, in the rendered tree and in the store
        #expect(fixture.hasPane, "the pane did not open")
        #expect(fixture.groupValue(chip.header) == "Expanded", "the \(chip.header) group is \(String(describing: fixture.groupValue(chip.header)))")
        #expect(fixture.store.openChoice(for: Fixture.conversation) == .open)
        #expect(fixture.store.selectedTab(for: Fixture.conversation) == .events)
        #expect(fixture.store.expandedGroups(for: Fixture.conversation).contains(chip.group))
        // a missing header is recorded as a failure but does not end the test, so the close and focus evidence below still runs
        let header = fixture.groupHeader(chip.header)
        #expect(header != nil, "no \(chip.header) group header; headers \(fixture.groupHeaderLabels)")
        #expect(header.flatMap(fixture.screenFrame(ofElement:)).map { $0.width > 0 && $0.height > 0 } ?? false)
        // whether the reveal actually moved keyboard or accessibility focus into the group before the close. This is read, not
        // asserted: it separates "focus never entered the group" from "focus entered and did not return".
        var headerFocus = false
        await waitUntil(timeout: 3) { fixture.pump(); headerFocus = fixture.focusedLabel?.hasPrefix(chip.header) == true; return headerFocus }
        print("TOPBAR focus [\(chip.header) before close] header expanded \(fixture.groupValue(chip.header) ?? "none"); "
            + "accessibility focus on the header \(headerFocus); first responder inside the pane "
            + "\(fixture.firstResponderIsInsidePane); focused element \(String(describing: fixture.focusedLabel))")
        print(fixture.focusDiagnostics(item: item, stage: "\(chip.header) pane open"))

        // then the open pane makes meta ineligible while a supervision chip shows, and the principal drops it
        let open = try #require(fixture.content)
        #expect(open.paneOpen, "the published content does not know the pane is open")
        #expect(!open.showsMeta(isNarrow: false))
        await waitUntil(timeout: 5) { fixture.pump(); return !metaIsDrawn(fixture) }
        #expect(!metaIsDrawn(fixture), "meta is still drawn with the pane open beside a supervision chip")

        // when the pane is closed from its own close button
        let close = try #require(fixture.contentElement(labelled: "Close right pane"), "no close button")
        #expect(M04ToolbarEvidence.press(close), "the close button did not accept a press")
        await waitUntil(timeout: 8) { fixture.keepActive(); fixture.pump(); return !fixture.hasPane }
        #expect(!fixture.hasPane, "the pane stayed open")

        // then focus is back on the chip where AppKit accepts it; otherwise the accessibility cursor is, and the keyboard fell back
        var outcome: TopBarFocusReturn?
        await waitUntil(timeout: 5) {
            fixture.keepActive()
            fixture.pump()
            outcome = fixture.focusReturn(to: item, label: label)
            return outcome != nil
        }
        print(fixture.focusDiagnostics(item: item, stage: "\(chip.header) after close"))
        let responder = String(describing: fixture.window.firstResponder)
        let accessibility = String(describing: fixture.focusedLabel)
        print("TOPBAR chip focus \(chip.header): \(outcome?.rawValue ?? "none"); responder \(responder); accessibility \(accessibility)")
        #expect(outcome != nil, "focus did not return to the chip; responder \(responder), accessibility \(accessibility)")
        #expect(fixture.item(chip.identifier) === item, "the chip item was rebuilt by the reveal")
    }
}
