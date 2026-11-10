//
//  TaskTopBarIntegratedHostedTests+Stability.swift
//  MainWindowFeatureTests
//

import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Testing

// MARK: - Identity and shrink

/// The toolbar's item objects must survive resizes, clock ticks and chip text changes: an item that AppKit rebuilt would
/// lose focus and flicker, and unique identifier strings alone do not show that.
extension TaskTopBarIntegratedHostedTests {

    private static let retainedIdentifiers = [
        Fixture.more, Fixture.inspector,
        "task-detail.chip.continuity", "task-detail.chip.notices", "task-detail.chip.access"
    ]

    /// The `NSToolbarItem` objects themselves, held strongly so a recycled address can never pass for identity.
    private func capture(_ fixture: Fixture) -> [String: NSToolbarItem] {
        Dictionary(uniqueKeysWithValues: Self.retainedIdentifiers.compactMap { id in fixture.item(id).map { (id, $0) } })
    }

    private func expectSameObjects(_ original: [String: NSToolbarItem], principal: NSToolbarItem, in fixture: Fixture, _ stage: String,
                                   sourceLocation: SourceLocation = #_sourceLocation) {
        for (identifier, object) in original {
            #expect(fixture.item(identifier) === object, "\(identifier) is a different NSToolbarItem object \(stage)", sourceLocation: sourceLocation)
        }
        #expect(fixture.principalItem === principal, "the principal is a different NSToolbarItem object \(stage)", sourceLocation: sourceLocation)
    }

    @Test func givenWideNarrowWide_whenTheWindowResizes_thenItemObjectsAreRetainedAndThePrincipalShrinksThenRegrows() async throws {
        // given a 120 character title in a wide window, so the principal is constrained at every width
        let fixture = await Fixture(.init(width: 1600, title: Fixture.TitleKind.long.text, resourceReturn: true))
        defer { fixture.close() }
        await waitUntil(timeout: 8) { fixture.pump(); return titleWidth(fixture) != nil && fixture.item("task-detail.chip.access") != nil }
        // the first title and principal width can belong to the shell's default band: set the size explicitly and settle first
        let initial = await settleGeometry(fixture, requested: 1600, expectsCap: true, stage: "initial wide")
        #expect(initial.isSettled, "the wide baseline never settled: \(initial.summary)")
        let principal = try #require(fixture.principalItem)
        let original = capture(fixture)
        #expect(original.count == Self.retainedIdentifiers.count, "missing items; have \(fixture.itemIdentifiers)")
        let wide = try #require(titleWidth(fixture))
        let wideFrame = try #require(fixture.screenFrame(of: principal)).width

        // when it narrows to 1000
        await fixture.resize(width: 1000)
        let narrowed = await settleGeometry(fixture, requested: 1000, expectsCap: true, stage: "narrowed")
        #expect(narrowed.isSettled, "the narrow geometry never settled: \(narrowed.summary)")

        // then the principal shrank to the narrow cap and is still on screen, with the same item objects
        let narrow = try #require(titleWidth(fixture))
        let narrowFrame = try #require(fixture.screenFrame(of: principal)).width
        #expect(narrow < wide - 1, "title stayed \(narrow) after shrinking from \(wide)")
        #expect(narrowFrame <= TopBarWidthBand.narrow.cap + 4, "principal \(narrowFrame) after shrinking exceeds the narrow cap")
        #expect(narrow >= TopBarPrincipalLayout.titleFloor)
        #expect(fixture.isOnScreen(principal) && fixture.isOnScreen(fixture.item(Fixture.more)) && fixture.isOnScreen(fixture.item(Fixture.inspector)))
        expectSameObjects(original, principal: principal, in: fixture, "after narrowing")

        // when it widens again
        await fixture.resize(width: 1600)
        let regrew = await settleGeometry(fixture, requested: 1600, expectsCap: true, stage: "widened again")
        #expect(regrew.isSettled, "the regrown geometry never settled: \(regrew.summary)")

        // then the principal regrew to what it was, with the same item objects
        let regrown = try #require(titleWidth(fixture))
        #expect(abs(regrown - wide) <= 2, "title \(regrown) after regrowing, was \(wide)")
        let regrownFrame = try #require(fixture.screenFrame(of: principal)).width
        #expect(abs(regrownFrame - wideFrame) <= 2, "principal \(regrownFrame) after regrowing, was \(wideFrame)")
        #expect(fixture.isOnScreen(principal) && fixture.isOnScreen(fixture.item(Fixture.more)) && fixture.isOnScreen(fixture.item(Fixture.inspector)))
        expectSameObjects(original, principal: principal, in: fixture, "after widening again")
    }

    @Test func givenARunningBadge_whenTheClockTicks_thenItemObjectsAndTheTitleWidthAreUnchanged() async throws {
        // given
        let fixture = await Fixture(.init(width: 1600, title: Fixture.TitleKind.short.text, resourceReturn: true))
        defer { fixture.close() }
        await waitUntil(timeout: 8) { fixture.pump(); return titleWidth(fixture) != nil && fixture.item("task-detail.chip.access") != nil }
        let principal = try #require(fixture.principalItem)
        let view = try #require(principal.view)
        let original = capture(fixture)
        let before = Set(fixture.strings(in: view))
        let width = try #require(titleWidth(fixture))

        // when the running clock advances
        await waitUntil(timeout: 6) { fixture.pump(); return Set(fixture.strings(in: view)) != before }

        // then the badge text really changed, and nothing else moved
        #expect(Set(fixture.strings(in: view)) != before, "the running clock never changed its accessible text: \(before)")
        #expect(abs((titleWidth(fixture) ?? 0) - width) <= 1)
        expectSameObjects(original, principal: principal, in: fixture, "after a clock tick")
    }

    @Test func givenTheNoticesChip_whenTheCountChanges_thenTheSameItemObjectShowsTheNewCount() async throws {
        // given
        let fixture = await Fixture(.init(width: 1600, notices: 3, resourceReturn: true))
        defer { fixture.close() }
        await waitUntil(timeout: 8) { fixture.pump(); return fixture.item("task-detail.chip.notices") != nil }
        let chip = try #require(fixture.item("task-detail.chip.notices"))
        let principal = try #require(fixture.principalItem)
        let original = capture(fixture)
        let oldCount = try #require(fixture.content?.noticeCount)
        #expect(oldCount >= 3)
        #expect(fixture.element(labelled: "Show \(oldCount) notices", in: chip) != nil, "strings \(chip.view.map(fixture.strings(in:)) ?? [])")

        // when the task gains notices
        fixture.setNotices(5)
        var newLabel = ""
        await waitUntil(timeout: 8) {
            fixture.pump()
            guard let chips = fixture.harness.sut.topBarContent?.chips(isNarrow: false), chips.noticeCount > oldCount else { return false }
            fixture.publish()
            newLabel = chips.noticesLabel
            return fixture.element(labelled: newLabel, in: chip) != nil
        }

        // then the chip item is the same object, in the bar, drawing the new count
        #expect(!newLabel.isEmpty, "the view model never reported more notices")
        #expect(fixture.item("task-detail.chip.notices") === chip, "the chip was rebuilt as another NSToolbarItem")
        #expect(fixture.element(labelled: newLabel, in: chip) != nil, "the chip does not read \(newLabel): \(chip.view.map(fixture.strings(in:)) ?? [])")
        #expect(fixture.isOnScreen(chip))
        expectSameObjects(original, principal: principal, in: fixture, "after a notice count change")
    }
}
