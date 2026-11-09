//
//  TaskTopBarIntegratedHostedTests.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TopBarMatrix

/// The width, sidebar and title matrix of the plan: 1000, 1100, 1279, 1280 and 1600 points, sidebar open and collapsed,
/// a short, a medium and a 120 character title.
enum TopBarMatrix {
    struct Point: CustomTestStringConvertible, Sendable {
        let width: CGFloat
        let collapsed: Bool
        let kind: TopBarIntegratedFixture.TitleKind

        var testDescription: String { "\(Int(width)) \(collapsed ? "sidebar collapsed" : "sidebar open"), \(kind.testDescription)" }
    }

    static let widths: [CGFloat] = [1000, 1100, 1279, 1280, 1600]

    static let points: [Point] = widths.flatMap { width in
        [false, true].flatMap { collapsed in
            TopBarIntegratedFixture.TitleKind.allCases.map { Point(width: width, collapsed: collapsed, kind: $0) }
        }
    }
}

// MARK: - TaskTopBarIntegratedHostedTests

/// The standalone task's top bar in the production shell and a real window: the principal item and the task view's
/// trailing items in one `NSToolbar`. Geometry comes from the actual toolbar items and their accessibility frames, never
/// from the pure solver alone; the solver is used only as the oracle for what the approved rule predicts from
/// independently measured parts. Needs the AppKit host.
@MainActor @Suite(.serialized) struct TaskTopBarIntegratedHostedTests {

    typealias Fixture = TopBarIntegratedFixture

    /// The principal's drawn title width, in points, `nil` while the title has no element.
    func titleWidth(_ fixture: Fixture) -> CGFloat? {
        guard let principal = fixture.principalItem, let element = fixture.element(labelled: fixture.config.title, in: principal) else {
            return nil
        }
        return fixture.screenFrame(ofElement: element)?.width
    }

    func metaIsDrawn(_ fixture: Fixture) -> Bool {
        guard let content = fixture.content, let principal = fixture.principalItem,
              let element = fixture.element(labelled: content.metaText, in: principal),
              let frame = fixture.screenFrame(ofElement: element) else { return false }
        return frame.width > 0
    }

    // MARK: - Matrix

    @Test(arguments: TopBarMatrix.points)
    func givenTheWorstCaseBar_whenTheWindowIsAtAMatrixPoint_thenPrincipalMoreAndInspectorAreOnScreenAndTheTitleFollowsTheLayoutRule(
        point: TopBarMatrix.Point
    ) async throws {
        // given the widest badge, all three chips, Take over and the resource return in one toolbar
        let fixture = await Fixture(.init(width: point.width, collapsed: point.collapsed, title: point.kind.text,
                                          badge: TopBarIdealWidths.widestBadge(), resourceReturn: true))
        defer { fixture.close() }
        let content = try #require(fixture.content, "the task never published its top bar content")
        let expected = fixture.expectedItems(chips: TopBarChip.allCases, content: content)
        await waitUntil(timeout: 8) { fixture.pump(); return titleWidth(fixture) != nil && fixture.problems(with: expected).isEmpty }

        // when the requested size is set explicitly and the window, the root view, the band and the principal have settled for
        // it: the first layout after mount can still belong to the shell's default band, so nothing is sampled before this. A
        // long title fills its cap, so only it is required to be at the cap; a title that fits keeps its ideal width.
        let settled = await settleGeometry(fixture, requested: point.width, expectsCap: point.kind == .long, stage: point.testDescription)
        #expect(settled.isSettled, "the geometry never settled before sampling: \(settled.summary)")
        let prediction = TopBarIdealWidths.predict(content: content, band: fixture.band, statusView: fixture.coordinator.buildConnectionStatusView())
        await waitUntil(timeout: 8) {
            fixture.pump()
            guard let slot = measureTitleSlot(fixture).slot, fixture.problems(with: expected).isEmpty else { return false }
            return abs(slot.width - prediction.solution.titleWidth) <= 3 && metaIsDrawn(fixture) == prediction.expectsMeta
        }
        logSlotMeasurement(fixture, prediction: prediction, stage: point.testDescription)

        // then the real items: principal, More and the inspector toggle are drawn in the bar, not overflowed
        let principal = try #require(fixture.principalItem, "no toolbar item draws the principal title; items: \(fixture.itemIdentifiers)")
        let diagnostics = "items \(fixture.itemIdentifiers), in bar \(fixture.items.filter { fixture.isInBar($0) }.map(\.itemIdentifier.rawValue))"
        #expect(fixture.isOnScreen(principal), "principal is not visible with a positive frame; \(diagnostics)")
        #expect(fixture.isOnScreen(fixture.item(Fixture.more)), "More is not visible; \(diagnostics)")
        #expect(fixture.isOnScreen(fixture.item(Fixture.inspector)), "the inspector toggle is not visible; \(diagnostics)")

        // then every control of the worst case is really drawn in the bar with a positive frame: the chips, Take over and
        // the resource return cannot disappear to relieve width pressure
        for problem in fixture.problems(with: expected) { Issue.record("\(problem); \(diagnostics)") }
        let own = fixture.itemIdentifiers.filter { $0.hasPrefix("task-detail.") }
        #expect(Set(own).count == own.count, "a task toolbar identifier is duplicated: \(own)")

        // then the principal never reports more than its cap
        let frame = try #require(fixture.screenFrame(of: principal))
        #expect(frame.width <= prediction.cap + 4, "principal \(frame.width) wider than its cap \(prediction.cap)")

        // then the title. The layout allocates the solver's width to the title's slot, measured from the title's leading edge to
        // the badge's leading edge less the gap; the glyph run inside it can be narrower when the text is truncated. A measurement
        // that cannot positively identify the badge in the principal fails, with no fallback to the prediction.
        let measurement = measureTitleSlot(fixture)
        let slot = try #require(measurement.slot, "the title slot could not be measured: \(measurement.failure ?? "unknown"); \(diagnostics)")
        let width = slot.glyph.width
        if point.kind == .short {
            #expect(abs(slot.width - prediction.titleIdeal) <= 2, "short title slot \(slot.width) is not its ideal \(prediction.titleIdeal)")
        }
        if width < prediction.titleIdeal - 2 {
            #expect(width >= TopBarPrincipalLayout.titleFloor, "constrained title glyph \(width) is under the \(TopBarPrincipalLayout.titleFloor) point floor")
        }
        let predicted = prediction.solution.titleWidth
        #expect(abs(slot.width - predicted) <= 3, "title slot \(slot.width) (glyph \(width)), the approved rule predicts \(predicted)")

        // then meta: hidden when ineligible; when eligible it drops only through the 60/80 rule
        let drawn = metaIsDrawn(fixture)
        if !prediction.metaEligible { #expect(!drawn, "meta is drawn although it is ineligible") }
        #expect(drawn == prediction.expectsMeta, "meta drawn \(drawn), the approved rule expects \(prediction.expectsMeta)")
        let summary = "glyph \(width), slot \(slot.width) of \(prediction.titleIdeal), meta \(drawn), principal \(frame.width)"
        print("TOPBAR matrix \(point.testDescription): \(summary), \(diagnostics)")
    }
}
