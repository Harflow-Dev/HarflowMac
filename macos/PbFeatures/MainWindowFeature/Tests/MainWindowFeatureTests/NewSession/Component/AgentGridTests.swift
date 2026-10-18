import AppKit
@testable import MainWindowFeature
import Observation
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@Suite struct AgentGridTests {

    private let allEnabled = [true, true, true, true]

    @Test func givenTheFirstCard_whenMovingRight_thenTheSecondCardIsNext() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .right, enabled: allEnabled) == 1)
    }

    @Test func givenTheFirstRow_whenMovingDown_thenTheCardBelowIsNext() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 1, direction: .down, enabled: allEnabled) == 3)
    }

    @Test func givenTheEdges_whenMovingOutward_thenThereIsNoNextCard() {
        // given / when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .left, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 0, direction: .up, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 3, direction: .right, enabled: allEnabled) == nil)
        #expect(AgentGrid.nextIndex(from: 3, direction: .down, enabled: allEnabled) == nil)
    }

    @Test func givenADisabledNeighbour_whenMovingHorizontally_thenItIsSkipped() {
        // given
        let enabled = [true, false, true, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .right, enabled: enabled) == 2)
    }

    @Test func givenADisabledCardBelow_whenMovingDown_thenNothingIsNext() {
        // given
        let enabled = [true, true, false, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .down, enabled: enabled) == nil)
    }

    @Test func givenFiveCards_whenMovingAcrossTheUsualTwoColumnGrid_thenTheLastRowRemainsReachable() {
        // given — BackendStyle.known currently supplies five cards; the fifth wraps to a final
        // one-card row and must still be reachable from the card above it.
        let enabled = [true, true, true, true, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 2, direction: .down, enabled: enabled) == 4)
        #expect(AgentGrid.nextIndex(from: 4, direction: .up, enabled: enabled) == 2)
    }

    @Test func givenAThreeColumnNarrowFallback_whenMovingDown_thenUsesThePresentedColumnCount() {
        // given — callers may adapt the grid's column count when the sheet narrows.
        let enabled = [true, true, true, true, true, true]

        // when / then
        #expect(AgentGrid.nextIndex(from: 0, direction: .down, enabled: enabled, columns: 3) == 3)
        #expect(AgentGrid.nextIndex(from: 5, direction: .up, enabled: enabled, columns: 3) == 2)
    }

    @Test func givenAdaptiveGridBoundaries_whenColumnCountIsResolved_thenSpacingNeverShrinksCardsBelowMinimum() {
        // given / when / then — the 12-point inter-card gap is part of the usable-width budget.
        #expect(AgentGrid.resolvedColumnCount(cardCount: 5, availableWidth: 402) == 2)
        #expect(AgentGrid.resolvedColumnCount(cardCount: 5, availableWidth: 408) == 3)
        #expect(AgentGrid.resolvedColumnCount(cardCount: 5, availableWidth: 704) == 5)
        #expect(AgentGrid.resolvedColumnCount(cardCount: 5, availableWidth: 420) == 3)
        #expect(AgentGrid.resolvedColumnCount(cardCount: 0, availableWidth: 760) == 1)
        #expect(AgentGrid.resolvedColumnCount(cardCount: 5, availableWidth: 0) == 1)
    }

    @MainActor @Test func givenAnEmptyGrid_whenFiveBackendCardsArriveAtTheSameWidth_thenTheHostedGridPresentsFiveCardsAcrossOneRow() async throws {
        // given — the real view starts empty, then receives the five-card catalog at the same width.
        _ = NSApplication.shared
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        defer { NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")) }
        let cards = ["claude", "codex", "vibe", "opencode", "antigravity"].enumerated().map { index, id in
            AgentCardModel(id: id, name: id.capitalized, helpText: id, isSelected: index == 0, isNotInstalled: false)
        }
        let source = CardSource(cards: [])
        let host = NSHostingView(rootView: AnyView(GridHarness(source: source).frame(width: 760, height: 240)))
        host.frame = CGRect(x: 0, y: 0, width: 760, height: 240)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await DisplayFrames.waitForPresentedFrame()

        // when
        source.cards = cards
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            let controls = cardControls(in: host)
            guard controls.count == 5 else { return false }
            return Set(controls.compactMap { accessibilityFrame($0) }.map { Int($0.midY.rounded()) }).count == 1
        }

        // then — all five real card controls share one row at the measured sheet width.
        let controls = cardControls(in: host)
        #expect(controls.count == 5)
        let frames = controls.compactMap { accessibilityFrame($0) }
        let yPositions = Set(frames.map { Int($0.midY.rounded()) })
        #expect(yPositions.count == 1)
        #expect(Set(frames.map { Int($0.midX.rounded()) }).count == 5)
        #expect(frames.allSatisfy { $0.width >= PbRadius.Metrics.newSessionAgentCardMinimumWidth - 1 })
    }

    @MainActor private func cardControls(in root: NSView) -> [NSObject] {
        // Assert through the hosted SwiftUI accessibility surface, not an AppKit implementation
        // detail such as NSButton. The cards remain real AX buttons if SwiftUI changes its native
        // backing view.
        allAccessibilityObjects(in: root).filter { object in
            accessibilityString(object, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && !(["accessibilityLabel", "accessibilityTitle", "accessibilityValue"]
                    .compactMap { accessibilityString(object, $0) }
.joined(separator: " ")
.isEmpty)
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func allAccessibilityObjects(in root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        for view in descendants(root) {
            for object in accessibilityTree(view) where seen.insert(ObjectIdentifier(object)).inserted { result.append(object) }
        }
        return result
    }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return result }
        for child in children { if let child = child as? NSObject { result += accessibilityTree(child) } }
        return result
    }

    private func accessibilityString(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func accessibilityFrame(_ object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityFrame() }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias FrameGetter = @convention(c) (AnyObject, Selector) -> CGRect
        let getter = unsafeBitCast(method, to: FrameGetter.self)
        return getter(object, selector)
    }
}

@MainActor @Observable private final class CardSource {
    var cards: [AgentCardModel]
    init(cards: [AgentCardModel]) { self.cards = cards }
}

private struct GridHarness: View {
    @Bindable var source: CardSource
    var body: some View { AgentGrid(cards: source.cards, onSelect: { _ in }) }
}
