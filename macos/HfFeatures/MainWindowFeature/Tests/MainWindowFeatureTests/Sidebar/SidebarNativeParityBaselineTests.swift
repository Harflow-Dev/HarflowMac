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
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
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
        #expect(baseline.promptFocus.requestedFirstResponder)
        #expect(baseline.promptFocus.arrowsKeptFocus)
        #expect(baseline.promptFocus.nativeTextUnchanged)
        #expect(baseline.promptFocus.modelMessageUnchanged)
        #expect(baseline.promptFocus.runningSelectionBefore == [1])
        #expect(baseline.promptFocus.runningSelectionAfter == baseline.promptFocus.runningSelectionBefore)
        #expect(baseline.promptFocus.recentSelectionBefore == [1])
        #expect(baseline.promptFocus.recentSelectionAfter == baseline.promptFocus.recentSelectionBefore)
        #expect(baseline.aliasSelection == [2, 3])
        #expect(fixture.runningOutline.numberOfRows == 4)
        #expect((0 ..< fixture.runningOutline.numberOfRows).map {
            (fixture.runningOutline.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id
        } == ["header:running", "task:abc123", "task:abc123-child", "group:review-bot"])
        let runningSignatures = (0 ..< fixture.runningOutline.numberOfRows).map { row in
            let view = fixture.runningOutline.view(atColumn: 0, row: row, makeIfNecessary: true)
            return RowObservation(index: row, identifier: "", rect: .zero, fittingHeight: 0,
                                  isGroupItem: nil, isGroupRowStyle: nil,
                                  accessibility: SidebarNativeBaselineFixture.accessibilityTree(view)).stableAXSignature
        }
        #expect(runningSignatures == expectedRunningAXSignatures)
        #expect(fixture.runningOutline !== fixture.outline)
        #expect(fixture.runningOutline.enclosingScrollView !== fixture.outline.enclosingScrollView)

        assertNativeFlagsAndFooter(baseline)
        assertViewportAllocation(baseline, fixture: fixture)
        let recentContentRows = baseline.rows.dropFirst().dropLast()
        #expect(recentContentRows.count == 4)
        #expect(recentContentRows.allSatisfy {
            $0.rect.minY >= fixture.outline.visibleRect.minY
                && $0.rect.maxY <= fixture.outline.visibleRect.maxY
        })
        #expect(baseline.firstRowFrame.minY >= baseline.effectiveViewportBottom - 1)
        #expect(baseline.firstRowFrame.maxY <= baseline.navigationFrame.minY)
        #expect(zip(baseline.rows, baseline.rows.dropFirst()).allSatisfy { current, next in
            next.rect.minY >= current.rect.maxY
        })
        let contentRows = baseline.rows.enumerated().filter { ![0, 5].contains($0.offset) }
        #expect(contentRows.allSatisfy { $0.element.rect.height >= $0.element.fittingHeight - 1 })
        #expect(baseline.rows.map(\.stableAXSignature) == expectedAXSignatures)
        for probe in KeyboardProbe.allCases {
            let result = try #require(baseline.keyboard[probe.rawValue])
            #expect(result.selectedRowsBefore == [1])
            #expect(result.firstResponder)
            #expect(result.selectedRowsAfter == expectedKeyboardSelection[probe])
        }
    }

    private func assertViewportAllocation(_ baseline: Baseline, fixture: SidebarNativeBaselineFixture) {
        // Native M04 adaptation: the fixed brand/navigation consumes 224 points. This
        // fixture's Running heading, two task rows and group occupy 14 + 48 + 48 + 54.
        // Pin both allocations as well as the resulting Recent edge; moving either section
        // must fail even if its rows still happen to fit. The native footer remains 61 below.
        let runningRowHeights = (0 ..< fixture.runningOutline.numberOfRows).map {
            fixture.runningOutline.rect(ofRow: $0).height
        }
        #expect(runningRowHeights == [14, 48, 48, 54])
        #expect(baseline.contentLayoutRect.maxY == 760)
        #expect(baseline.effectiveViewportTop == 372)
        let runningFrame = fixture.runningOutline.enclosingScrollView!.convert(fixture.runningOutline.enclosingScrollView!.bounds, to: nil)
        #expect(runningFrame.maxY == baseline.contentLayoutRect.maxY - 224)
        #expect(runningFrame.height == 164)
        #expect(abs(runningFrame.minY - baseline.scrollFrame.maxY) <= 1)
    }

    private func assertNativeFlagsAndFooter(_ baseline: Baseline) {
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
        #expect(baseline.navigationFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
        #expect(baseline.scrollFrame.minY >= baseline.contentLayoutRect.minY - 1)
        #expect(baseline.scrollFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
        // The compact footer reserves only the appearance icons and Settings control; connection
        // status now lives in the main window title bar.
        #expect(baseline.effectiveViewportBottom == 61)
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

private let expectedAXSignatures: [[String]] = [
    ["AXHeading|Recent work||"],
    ["AXStaticText||Refactor the parser|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline workflow|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline shortcut|", "AXUnknown|Failed||", "AXStaticText||Child workflow|",
     "AXStaticText||Vibe · repo|"],
    ["AXStaticText||Bump dependencies|", "AXUnknown|Failed||", "AXStaticText||Vibe · app|"],
    []
]

// Rows 2 and 3 are the workflow and shortcut aliases of the same logical destination.
// Down must synchronize both, just as the explicit alias-selection probe requires.
private let expectedKeyboardSelection: [KeyboardProbe: [Int]] = [
    .up: [1], .down: [2, 3], .home: [1], .end: [1], .pageUp: [1], .pageDown: [1],
    .commandA: [1], .return: [1], .space: [1], .letter: [1]
]

private let expectedRunningAXSignatures: [[String]] = [
    ["AXHeading|Running||"],
    ["AXStaticText||Fix the login bug|", "AXUnknown|Running||", "AXButton|Collapse Fix the login bug|Expanded|",
     "AXStaticText||Claude · repo · 1 sub-task|"],
    ["AXStaticText||Write the migration|", "AXUnknown|Running||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||review-bot|", "AXUnknown|Claude, Codex||", "AXStaticText||Parallel run · 1 of 2 finished|",
     "AXUnknown|Running||", "AXButton|Expand or collapse review-bot|Collapsed|"]
]
