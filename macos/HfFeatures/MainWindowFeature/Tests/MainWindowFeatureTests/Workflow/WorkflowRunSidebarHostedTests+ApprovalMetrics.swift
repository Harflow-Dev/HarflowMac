import AppKit
@testable import MainWindowFeature
import Testing

// MARK: - ApprovalMetrics

/// Frames and flags measured from a hosted selected-node pane with pending approvals. Every frame is in window base
/// coordinates (origin bottom-left), the space the accessibility frames are converted into.
@MainActor
struct ApprovalMetrics {
    enum Hit: Equatable {
        /// The accessibility hit test answered with the expected button or one of its descendants at the action's centre.
        case target
        /// The hit test answered nothing; recorded explicitly, the geometry carries the proof.
        case noAnswer
        /// The hit test answered with some other element, so something else covers the action.
        case covered
    }

    struct HitTest: CustomStringConvertible {
        let identifier: String
        let hit: Hit
        /// The hit element and its accessibility ancestors, for failure messages.
        var chain = ""
        var description: String { "\(identifier)=\(hit) [\(chain)]" }
    }

    let ids: [String]
    let demand: CallerApprovalDemand
    let window: CGRect
    let paneFrame: CGRect
    /// The approval region's own frame, read from the panel's frame probe (its accessibility group stops at the last child).
    let region: CGRect
    let composer: CGRect
    let approves: [String: CGRect]
    let rejects: [String: CGRect]
    let details: [String: CGRect]
    let labels: [String: CGRect]
    let hitTests: [HitTest]
    let feedHeight: CGFloat
    let stepCountLinePresent: Bool
    let topRegion: NSScrollView?
    let cardScroll: NSScrollView?
    let barScroll: NSScrollView?
    let pane: ApprovalPane

    init(pane: ApprovalPane, requestIDs: [String]) throws {
        let fixture = pane.fixture
        func frame(_ identifier: String) -> CGRect? { fixture.element(identifier).flatMap { fixture.frame($0) } }
        let region = try #require(pane.regionFrame)
        var approves: [String: CGRect] = [:], rejects: [String: CGRect] = [:], details: [String: CGRect] = [:], labels: [String: CGRect] = [:]
        for id in requestIDs {
            approves[id] = frame("approval-approve-\(id)")
            rejects[id] = frame("approval-reject-\(id)")
            details[id] = frame("approval-details-\(id)")
            labels[id] = frame("approval-bar-label-\(id)")
        }
        let scrolls = pane.paneScrollViews.filter { !($0 is ActivityFeedNativeScrollView) }
        let outermost = scrolls.filter { scroll in !scrolls.contains { $0 !== scroll && Self.isDescendant(scroll, of: $0) } }
        let fullRegion = region.insetBy(dx: -1, dy: -1)
        let inRegion = outermost.filter {
            let rect = pane.windowFrame($0)
            return rect.height > 0 && fullRegion.contains(rect)
        }
        let sortedRegion = inRegion.sorted { pane.windowFrame($0).maxY > pane.windowFrame($1).maxY }
        var tests: [HitTest] = []
        for id in requestIDs {
            tests.append(Self.hitTest(identifier: "approval-approve-\(id)", frame: approves[id], region: region, fixture: fixture))
            tests.append(Self.hitTest(identifier: "approval-reject-\(id)", frame: rejects[id], region: region, fixture: fixture))
        }
        let paneRect = try #require(frame("workflow-selected-sidebar"))
        self.ids = requestIDs
        self.pane = pane
        self.demand = pane.demand.value
        self.window = try #require(fixture.window.contentView).frame
        self.paneFrame = paneRect
        self.region = region
        self.composer = try #require(frame("parallel-column-composer"))
        self.approves = approves
        self.rejects = rejects
        self.details = details
        self.labels = labels
        self.hitTests = tests
        self.feedHeight = pane.paneView.flatMap { pane.allViews($0).compactMap { $0 as? ActivityFeedNativeScrollView }.first }?.bounds.height ?? 0
        self.stepCountLinePresent = pane.contains("activity item")
        // The bar stack's scroll view is the one that holds the decision buttons; the card's is the other.
        let barScroll = pane.paneView
.flatMap { root in
            pane.allViews(root).first { ($0.accessibilityIdentifier()).hasPrefix("approval-approve-") }?.enclosingScrollView
        }
.flatMap { scroll in fullRegion.contains(pane.windowFrame(scroll)) ? scroll : nil }
        self.barScroll = barScroll
        self.cardScroll = sortedRegion.first { $0 !== barScroll }
        let aboveRegion = outermost.filter { !inRegion.contains($0) && pane.windowFrame($0).height < paneRect.height - 1 }
        self.topRegion = aboveRegion.max { pane.windowFrame($0).maxY < pane.windowFrame($1).maxY }
    }

    private static func isDescendant(_ view: NSView, of ancestor: NSView) -> Bool {
        var current = view.superview
        while let value = current { if value === ancestor { return true }; current = value.superview }
        return false
    }

    private static func hitTest(identifier: String, frame: CGRect?, region: CGRect, fixture: RedesignHost) -> HitTest {
        guard let frame, frame.width > 0, frame.height > 0 else { return HitTest(identifier: identifier, hit: .covered) }
        let center = fixture.window.convertPoint(toScreen: CGPoint(x: frame.midX, y: frame.midY))
        guard let answer = fixture.host.accessibilityHitTest(center) as? NSObject else { return HitTest(identifier: identifier, hit: .noAnswer) }
        let (identifies, chain) = identifies(answer, as: identifier, fixture: fixture)
        return HitTest(identifier: identifier, hit: identifies ? .target : .covered, chain: chain)
    }

    /// The hit element is the expected button or a descendant of it: it, its control (for a cell) or one of its accessibility ancestors
    /// carries the identifier.
    private static func identifies(_ answer: NSObject, as identifier: String, fixture: RedesignHost) -> (Bool, String) {
        var current: NSObject? = answer
        var chain: [String] = []
        for _ in 0 ..< 8 {
            guard let element = current else { break }
            // A native button answers with its cell, whose control is the button that carries the identifier.
            let own = (element as? NSCell)?.controlView?.accessibilityIdentifier() ?? fixture.string(element, "accessibilityIdentifier") ?? ""
            chain.append("\(type(of: element))#\(own)")
            if own == identifier { return (true, chain.joined(separator: " < ")) }
            let parent = NSSelectorFromString("accessibilityParent")
            current = element.responds(to: parent) ? element.perform(parent)?.takeUnretainedValue() as? NSObject : nil
        }
        return (false, chain.joined(separator: " < "))
    }

    // MARK: Predicates

    private func inside(_ outer: CGRect, _ inner: CGRect?) -> Bool {
        guard let inner, inner.width > 0, inner.height > 0 else { return false }
        return outer.insetBy(dx: -1, dy: -1).contains(inner)
    }

    var regionIsVisible: Bool {
        region.height >= 0 && inside(window, region) && inside(paneFrame, region) && region.minY >= composer.maxY - 1
    }

    /// Every expected request has an approve and a reject frame, and every one is whole inside the region.
    var actionsAreVisible: Bool {
        !ids.isEmpty && ids.allSatisfy { inside(region, approves[$0]) && inside(region, rejects[$0]) }
    }

    /// Every expected request has a details frame, whole inside the region.
    var detailsAreInsideRegion: Bool { !ids.isEmpty && ids.allSatisfy { inside(region, details[$0]) } }

    func barLabelsPresent(_ ids: [String]) -> Bool { ids.allSatisfy { inside(region, labels[$0]) } }

    /// An accessibility hit test at each action's centre answered with that very button (or a descendant), for every expected action.
    var allHitsReachTheirTarget: Bool { hitTests.count == ids.count * 2 && hitTests.allSatisfy { $0.hit == .target } }

    var regionHeight: CGFloat { region.height }

    var topRegionHeight: CGFloat { topRegion.map { pane.windowFrame($0).height } ?? 0 }

    var cardScrolls: Bool { cardScroll.map { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 } ?? false }

    var cardViewportHeight: CGFloat { cardScroll.map(\.contentView.bounds.height) ?? 0 }

    var barStackScrolls: Bool { barScroll.map { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 1 } ?? false }

    var topRegionIsNatural: Bool { topRegion.map { ($0.documentView?.frame.height ?? 0) <= $0.contentView.bounds.height + 1 } ?? false }

    /// Scrolls the card to its end and back; every expected action frame must exist and be where it was.
    func cardScrollKeepsActionsFixed(_ pane: ApprovalPane) -> Bool {
        guard let scroll = cardScroll, let document = scroll.documentView else { return false }
        func snapshot() -> [CGRect?] {
            pane.fixture.host.layoutSubtreeIfNeeded()
            return ids.flatMap { id in
                ["approval-approve-\(id)", "approval-reject-\(id)"].map { identifier in
                    pane.fixture.element(identifier).flatMap { pane.fixture.frame($0) }
                }
            }
        }
        let before = snapshot()
        guard before.allSatisfy({ $0 != nil }), before.count == ids.count * 2 else { return false }
        let travel = max(0, document.frame.height - scroll.contentView.bounds.height)
        for target in [document.isFlipped ? travel : 0, document.isFlipped ? 0 : travel] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
            scroll.reflectScrolledClipView(scroll.contentView)
            let after = snapshot()
            let unchanged = zip(before, after).allSatisfy { lhs, rhs in
                guard let lhs, let rhs else { return false }
                return abs(lhs.minX - rhs.minX) < 0.5 && abs(lhs.minY - rhs.minY) < 0.5
            }
            guard after.count == before.count, unchanged else { return false }
        }
        return true
    }

    var description: String {
        let summary = [
            "demand=\(demand)", "region=\(region)", "pane=\(paneFrame)", "composer=\(composer)", "feed=\(feedHeight)",
            "cardScroll=\(cardScroll.map { "\(pane.windowFrame($0)) doc=\($0.documentView?.frame.height ?? -1)" } ?? "nil")",
            "barScroll=\(barScroll.map { "\(pane.windowFrame($0)) doc=\($0.documentView?.frame.height ?? -1)" } ?? "nil")",
            "top=\(topRegion.map { "\(pane.windowFrame($0)) doc=\($0.documentView?.frame.height ?? -1)" } ?? "nil")",
            "approves=\(approves)", "rejects=\(rejects)", "details=\(details)", "labels=\(labels)", "hits=\(hitTests)"
        ]
        return summary.joined(separator: "\n  ")
    }
}

// MARK: - Pane lookups and scrolling

extension ApprovalPane {
    /// The window frame of the first accessibility element whose label, title or value contains `text`.
    func frame(ofElementContaining text: String) -> CGRect? {
        guard let pane = paneView else { return nil }
        let element = allViews(pane).flatMap { fixture.elements(in: $0) }.first { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { fixture.string(element, $0)?.contains(text) == true }
        }
        return element.flatMap { fixture.frame($0) }
    }

    /// The approval region's own frame, from the invisible probe behind the pinned panel.
    var regionFrame: CGRect? {
        paneView.flatMap { root in allViews(root).first { $0.accessibilityIdentifier() == "workflow-selected-approval-frame" } }
            .map { windowFrame($0) }
    }

    func contains(_ text: String) -> Bool {
        guard fixture.element("workflow-selected-sidebar") != nil, let pane = paneView else { return false }
        return allViews(pane).flatMap { fixture.elements(in: $0) }.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { fixture.string(element, $0)?.contains(text) == true }
        }
    }

    struct Reach {
        var approve = false
        var reject = false
        var viewportAboveComposer = false
    }

    /// Scrolls the request's bar into the bar viewport (or the region when the bar is not in a scroll view) and reports
    /// whether both of its actions are whole inside that viewport.
    func scrollIntoView(requestID: String) throws -> Reach {
        let approveID = "approval-approve-\(requestID)", rejectID = "approval-reject-\(requestID)"
        let button = try #require(paneView.flatMap { allViews($0).first { $0.accessibilityIdentifier() == approveID } })
        button.scrollToVisible(button.bounds)
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        let region = try #require(regionFrame)
        let composer = try #require(fixture.element("parallel-column-composer").flatMap { fixture.frame($0) })
        let viewport = button.enclosingScrollView.map { scroll in windowFrame(scroll.contentView).intersection(region) } ?? region
        func whole(_ frame: CGRect?) -> Bool {
            guard let frame, frame.width > 0, frame.height > 0 else { return false }
            return viewport.insetBy(dx: -1, dy: -1).contains(frame)
        }
        return Reach(approve: whole(windowFrame(button)), reject: whole(fixture.element(rejectID).flatMap { fixture.frame($0) }),
                     viewportAboveComposer: viewport.minY >= composer.maxY - 1)
    }

    struct DetailsReach {
        var cardViewport: CGFloat = 0
        var visibleHeight: CGFloat = 0
        var expectedHeight: CGFloat = 0
        /// The details of the request came into the card viewport as far as the viewport allows.
        var isReachable: Bool { cardViewport > 0 && visibleHeight >= expectedHeight - 1 }
    }

    /// Scrolls the request's details into the card viewport and reports how much of them shows against how much can.
    func scrollDetailsIntoView(requestID: String) throws -> DetailsReach {
        let details = try #require(paneView.flatMap { allViews($0).first { $0.accessibilityIdentifier() == "approval-details-\(requestID)" } })
        let scroll = try #require(details.superview?.enclosingScrollView, "the details sit inside the card scroll view")
        details.scrollToVisible(details.bounds)
        fixture.host.layoutSubtreeIfNeeded()
        fixture.host.displayIfNeeded()
        let viewport = windowFrame(scroll.contentView)
        let frame = windowFrame(details)
        let visible = frame.intersection(viewport)
        return DetailsReach(cardViewport: viewport.height, visibleHeight: visible.isNull ? 0 : visible.height,
                            expectedHeight: min(frame.height, viewport.height))
    }
}
