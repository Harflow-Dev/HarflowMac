//
// SidebarNativeParityBaselineTests.swift
// MainWindowFeatureTests
//
// The recorded native unified-outline baseline for the sidebar adapter (M04). The first run writes a
// machine-readable observation outside the repository; reviewed stable fields are pinned here,
// including the per-row AX signatures from the actual full observe. Discovery is ID-based on the
// single unified outline that owns the navigation entries — the obsolete AXButton navigation frame
// lookup is gone.
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
    @Test func givenTheUnifiedSidebarOutline_whenHosted_thenRecordNativeParityBaseline() async throws {
        // given — explicit local rows cover every unified presentation kind in a real window; no
        // backend or persisted task data is used.
        let fixture = try await SidebarNativeBaselineFixture()
        defer { fixture.close() }

        // when — let native fitting and disclosure layout settle, then observe public behavior.
        await fixture.settle()
        let baseline = fixture.observe()
        fixture.write(baseline)

        // then — missing public accessibility is a baseline issue, never an empty pass.
        #expect(baseline.rows.count == 15, "The unified baseline must contain exactly fifteen rows")
        #expect(baseline.rows.allSatisfy { !$0.accessibility.isEmpty },
                "Every unified baseline row must expose an accessibility element")
        #expect(baseline.missingAccessibility.isEmpty,
                "Native sidebar AX baseline is incomplete: \(baseline.missingAccessibility)")

        // Single-outline ID-based discovery: exactly one outline owns the navigation entry, the
        // pinned unified entry order holds, and the semantic probes' rows are pinned indices.
        #expect(SidebarNativeBaselineFixture.unifiedOutlines(in: fixture.controller.view).count == 1)
        #expect(SidebarNativeBaselineFixture.entryIDs(in: fixture.outline) == SidebarNativeBaselineFixture.unifiedEntryIDs)
        #expect(fixture.anchorRow == 10 && fixture.groupRow == 8)
        #expect(fixture.workflowAliasRow == 11 && fixture.shortcutAliasRow == 12)
        #expect(SidebarNativeBaselineFixture.row(of: "task:abc123", in: fixture.outline) == 6)
        #expect(SidebarNativeBaselineFixture.row(of: "navigation:statistics", in: fixture.outline) == 4)

        // Stable public control settings, fixed chrome, shared viewport and semantic row geometry.
        assertNativeFlagsAndChrome(baseline)
        assertSharedViewport(baseline)
        assertUnifiedRowGeometry(baseline, fixture: fixture)

        #expect(baseline.rows.map(\.stableAXSignature) == expectedUnifiedAXSignatures)

        // The actual prompt NSTextView keeps focus, text and selection isolated from the outline.
        #expect(baseline.promptFocus.requestedFirstResponder)
        #expect(baseline.promptFocus.arrowsKeptFocus)
        #expect(baseline.promptFocus.nativeTextUnchanged)
        #expect(baseline.promptFocus.modelMessageUnchanged)
        #expect(baseline.promptFocus.selectionBefore == [fixture.anchorRow])
        #expect(baseline.promptFocus.selectionAfter == baseline.promptFocus.selectionBefore)

        // The workflow and shortcut aliases of one logical destination stay programmatically
        // selectable together at their pinned unified indices (11 and 12).
        #expect(baseline.aliasSelection == [fixture.workflowAliasRow, fixture.shortcutAliasRow])

        // Keyboard across nav, Running and Recent, anchored by entry id; AppKit skips the
        // destinationless headings and the adapter synchronizes both alias rows on the next selection.
        #expect(baseline.keyboard.count == KeyboardProbe.allCases.count)
        let expectedSelection = expectedUnifiedKeyboardSelection(fixture)
        let expectedAnchors = expectedUnifiedKeyboardAnchors(fixture)
        for probe in KeyboardProbe.allCases {
            let result = try #require(baseline.keyboard[probe.rawValue])
            #expect(result.selectedRowsBefore == expectedAnchors[probe])
            #expect(result.firstResponder)
            #expect(result.represented)
            #expect(result.selectedRowsAfter == expectedSelection[probe])
        }
    }

    /// Reviewed unified geometry (native outline coordinates): five navigation rows tile into a
    /// 160-point block followed by a 13-point section gap, the Running heading opens at 173, Recent work at 350, the sentinel at 574.
    private func assertUnifiedRowGeometry(_ baseline: Baseline, fixture: SidebarNativeBaselineFixture) {
        #expect(baseline.rows.first?.rect.minY == 0)
        #expect(zip(baseline.rows, baseline.rows.dropFirst()).enumerated().allSatisfy { index, pair in
            pair.1.rect.minY - pair.0.rect.maxY == ([4, 8].contains(index) ? 13 : 0)
        })
        #expect(baseline.rows[5].rect.minY == 173 && baseline.rows[5].rect.maxY == 187)
        #expect(baseline.rows[9].rect.minY == 350 && baseline.rows[9].rect.maxY == 364)
        #expect(baseline.rows[14].rect.minY == 574 && baseline.rows[14].rect.maxY == 575)
        // Headings, Running content, the Recent content rows and the sentinel have exact heights.
        #expect(Array(baseline.rows.map(\.rect.height).dropFirst(5)) == [14, 48, 48, 54, 14, 48, 48, 66, 48, 1])
        // Each navigation row fits 32 points; section gaps remain outside native row rects.
        #expect(baseline.rows[0 ... 4].allSatisfy { $0.fittingHeight == 32 })
        #expect(baseline.rows[0 ... 4].map(\.rect.height).reduce(0, +) == 160)
        // The group disclosure retains its observed 54-point slot.
        #expect(baseline.rows[fixture.groupRow].fittingHeight == 54)
        // Content never clips its hosted fit, and every row stays inside the shared viewport.
        let contentRows = baseline.rows.filter { ![5, 9, 14].contains($0.index) }
        #expect(contentRows.allSatisfy { $0.rect.height >= $0.fittingHeight - 1 })
        let visible = fixture.outline.visibleRect
        #expect(baseline.rows.allSatisfy { $0.rect.minY >= visible.minY && $0.rect.maxY <= visible.maxY })
    }

    /// Reviewed unified viewport: one shared scroll under the fixed brand header and above the fixed
    /// footer — bottom 61, top 716, height 655, content layout 760 tall, and the navigation block
    /// flush at the viewport top.
    private func assertSharedViewport(_ baseline: Baseline) {
        #expect(baseline.contentLayoutRect.maxY == 760)
        #expect(baseline.effectiveViewportBottom == 61)
        #expect(baseline.effectiveViewportTop == 716)
        #expect(baseline.scrollFrame.minY == 61 && baseline.scrollFrame.maxY == 716)
        #expect(baseline.scrollFrame.maxY - baseline.scrollFrame.minY == 655)
        #expect(baseline.navigationFrame.maxY - baseline.navigationFrame.minY == 160)
        #expect(baseline.navigationFrame.maxY == baseline.effectiveViewportTop)
        #expect(baseline.firstRowFrame.maxY == baseline.effectiveViewportTop)
    }

    private func assertNativeFlagsAndChrome(_ baseline: Baseline) {
        // Reviewed public control settings and semantic chrome, not object addresses or internals.
        #expect(baseline.flags.allowsTypeSelect)
        #expect(!baseline.flags.floatsGroupRows)
        #expect(baseline.flags.indentationPerLevel == 12)
        #expect(!baseline.flags.allowsMultipleSelection)
        #expect(baseline.flags.allowsEmptySelection)
        #expect(!baseline.flags.refusesFirstResponder)
        #expect(baseline.flags.selectionHighlightStyle == 1)
        #expect(baseline.flags.rowSizeStyle == 2)
        #expect(baseline.flags.style == 3)
        // B5: the owned native scroll view keeps zero contentInsets; the footer stays outside it.
        #expect(baseline.flags.contentInsets.top == 0)
        #expect(baseline.flags.contentInsets.left == 0)
        #expect(baseline.flags.contentInsets.right == 0)
        #expect(baseline.flags.contentInsets.bottom >= 0)
        #expect(baseline.rows.allSatisfy { $0.rect.width > 0 })
        #expect(baseline.navigationFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
        #expect(baseline.scrollFrame.minY >= baseline.contentLayoutRect.minY - 1)
        #expect(baseline.scrollFrame.maxY <= baseline.contentLayoutRect.maxY + 1)
    }

    /// Keyboard expectations from the actual observed unified baseline: `down` from the Recent task
    /// selects both aliased rows (11, 12); `up` crosses the unselectable Recent heading onto the
    /// group row (8); `home` is a viewport scroll, not a selection jump, and keeps the anchor — the
    /// same observed public semantics as the old List baseline; `end`, `pageUp`, `pageDown`,
    /// `commandA`, `return`, `space` and the type-select letter also keep the anchor. The two
    /// cross-section probes pin navigation ↔ Running travel: `runningUp` walks from the Running
    /// task up onto the Statistics navigation row, and `statisticsDown` walks back down, skipping
    /// the destinationless Running heading, onto the Running task.
    private func expectedUnifiedKeyboardSelection(_ fixture: SidebarNativeBaselineFixture) -> [KeyboardProbe: [Int]] {
        let anchor = fixture.anchorRow
        return [
            .up: [fixture.groupRow], .down: [fixture.workflowAliasRow, fixture.shortcutAliasRow],
            .home: [anchor], .end: [anchor], .pageUp: [anchor], .pageDown: [anchor],
            .commandA: [anchor], .return: [anchor], .space: [anchor], .letter: [anchor],
            .runningUp: [4], .statisticsDown: [6]
        ]
    }

    /// Each probe's pinned before-selection: the Recent anchor (10) for the ten original probes,
    /// the Running task (6) for `runningUp`, and Statistics (4) for `statisticsDown`.
    private func expectedUnifiedKeyboardAnchors(_ fixture: SidebarNativeBaselineFixture) -> [KeyboardProbe: [Int]] {
        Dictionary(uniqueKeysWithValues: KeyboardProbe.allCases.map { probe in
            (probe, [probe == .runningUp ? 6 : probe == .statisticsDown ? 4 : fixture.anchorRow])
        })
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

private let expectedRecentAXSignatures: [[String]] = [
    ["AXHeading|Recent work||"],
    ["AXStaticText||Refactor the parser|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline workflow|", "AXUnknown|Done||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||Baseline shortcut|", "AXUnknown|Failed||", "AXStaticText||Child workflow|",
     "AXStaticText||Vibe · repo|"],
    ["AXStaticText||Bump dependencies|", "AXUnknown|Failed||", "AXStaticText||Vibe · app|"],
    []
]

private let expectedRunningAXSignatures: [[String]] = [
    ["AXHeading|Running||"],
    ["AXStaticText||Fix the login bug|", "AXUnknown|Running||", "AXButton|Collapse Fix the login bug|Expanded|",
     "AXStaticText||Claude · repo · 1 sub-task|"],
    ["AXStaticText||Write the migration|", "AXUnknown|Running||", "AXStaticText||Codex · repo|"],
    ["AXStaticText||review-bot|", "AXUnknown|Claude, Codex||", "AXStaticText||Parallel run · 1 of 2 finished|",
     "AXUnknown|Running||", "AXButton|Expand or collapse review-bot|Collapsed|"]
]

private let expectedUnifiedAXSignatures: [[String]] = [
    ["AXStaticText||New task|"], ["AXStaticText||Needs you, 3 pending|"],
    ["AXStaticText||Workflows|"], ["AXStaticText||Resources|"], ["AXStaticText||Statistics|"]
] + expectedRunningAXSignatures + expectedRecentAXSignatures
