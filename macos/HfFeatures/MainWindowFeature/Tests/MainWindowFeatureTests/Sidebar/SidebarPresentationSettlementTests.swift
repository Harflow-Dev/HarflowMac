import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

/// Deterministic presentation-settlement regressions for the native sidebar's history gate.
/// These tests drive the coordinator's hosted reporting boundary directly with fabricated
/// presentation reports, so no animation cadence participates: every sentinel admission can
/// only follow a committed (height, settlement) pair at the native flush boundary.
@MainActor
@Suite(.serialized)
struct SidebarPresentationSettlementTests {

    // MARK: zero-start blocked

    @Test func givenUnseenAnimatedItem_whenCellRealizes_thenGateHoldsBeforeAnyHostedCallback() throws {
        // given — one unreported zero-start task row ahead of the sentinel.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "first"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:first")])

        // when — AppKit realizes the fresh animated cell; no hosted report has run yet.
        let cell = try #require(fixture.realizeCell(row: 0))
        #expect(cell.animate == true)

        // then — the association is marked unsettled BEFORE the first callback, so admission
        // stays blocked across the un-reported layout window.
        #expect(fixture.coordinator.hasUnsettledPresentations)
        #expect(box.latestHostedReport == nil)
    }

    // MARK: evidence sequence — revoke, never leave a stale true standing

    @Test func givenAdmittedSentinel_whenFreshItemCommitsProvisionalHeights_thenTrueIsRevokedUntilFinalHeightSettles() throws {
        // given — settled short content whose sentinel is already admitted visible.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.coordinator.seenIDs = ["task:first"]
        fixture.register(entries: [fixture.taskEntry(id: "first"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        _ = try #require(fixture.realizeCell(row: 0))
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications == [SettlementAdmission(visible: true, revision: 0)])
        #expect(!fixture.coordinator.hasUnsettledPresentations)

        // when — a fresh animated disclosure brings its intermediate zero-occupancy commit.
        let freshBox = try #require(fixture.insertFreshItem(id: "second"))
        let freshCell = try #require(fixture.realizeCell(row: 1))
        #expect(freshCell.animate == true)
        #expect(fixture.coordinator.hasUnsettledPresentations)
        freshBox.height = HfRadius.Metrics.hairlineStroke
        fixture.noteRowHeight(1)
        fixture.coordinator.deliverGeometry()

        // then — the standing true is actively revoked: publication turns false while the
        // presentation remains unsettled, never merely skipped.
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: false, revision: 0))

        // when — the settled report commits the final height at the flush boundary.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: freshBox.reportGeneration),
            box: freshBox, cell: freshCell, generation: freshBox.reportGeneration
        )

        // then — the gate cleared exactly with the final height commit, and true is readmitted.
        #expect(freshBox.height == 44)
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications == [
            SettlementAdmission(visible: true, revision: 0), SettlementAdmission(visible: false, revision: 0), SettlementAdmission(visible: true, revision: 0)
        ])
        // No admission ever interleaved between the revoke and the settle.
        #expect(fixture.historyPublications.filter(\.visible).count == 2)
    }

    // MARK: short content legitimate true

    @Test func givenSettledShortContent_whenGeometryIsRedelivered_thenTrueAdmitsExactlyOnce() throws {
        // given — fully settled short content with the sentinel inside the viewport.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.coordinator.seenIDs = ["task:first"]
        fixture.register(entries: [fixture.taskEntry(id: "first"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        _ = try #require(fixture.realizeCell(row: 0))

        // when — geometry delivers twice without any presentation change.
        fixture.coordinator.deliverGeometry()
        fixture.coordinator.deliverGeometry()

        // then — the sentinel admits visible exactly once; settled short content is legitimate.
        #expect(fixture.historyPublications == [SettlementAdmission(visible: true, revision: 0)])
        #expect(!fixture.coordinator.hasUnsettledPresentations)
    }

    // MARK: logical-0 removal

    @Test func givenFadingDisclosure_whenLogicalTargetIsZero_thenGateHoldsUntilProgressReachesZero() throws {
        // given — a fading task row animating toward its final logical target 0.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "fading"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:fading")])
        let cell = try #require(fixture.realizeCell(row: 0))
        #expect(fixture.coordinator.hasUnsettledPresentations)

        // when — the fade is mid-flight.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0.5, naturalHeight: 44, logicalTarget: 0,
                        authorityGeneration: box.reportGeneration),
            box: box, cell: cell, generation: box.reportGeneration
        )

        // then — the intermediate progress holds the gate and commits provisional height only.
        #expect(box.height == 22)
        #expect(fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: false, revision: 0))

        // when — the presentation reaches its final logical target zero.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0, naturalHeight: 44, logicalTarget: 0,
                        authorityGeneration: box.reportGeneration),
            box: box, cell: cell, generation: box.reportGeneration
        )

        // then — the removal settles at logical target zero and the gate clears with it.
        #expect(box.height == 0)
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: true, revision: 0))
    }

    // MARK: final height commits before admission

    @Test func givenSettledReportInsideNativeOperation_whenFlushBoundaryHolds_thenAdmissionWaitsForCommittedPair() throws {
        // given — a fresh zero-start row with the sentinel inside the viewport.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "held"), fixture.sentinelEntry()],
                         heights: [22, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:held")])
        let cell = try #require(fixture.realizeCell(row: 0))
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: false, revision: 0))

        // when — the final settled report is recorded while the flush boundary holds it.
        fixture.coordinator.beginNativeOperation()
        let heldGeneration = box.reportGeneration
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: heldGeneration),
            box: box, cell: cell, generation: heldGeneration
        )
        #expect(fixture.coordinator.hasUnsettledPresentations)
        #expect(box.height != 44)
        fixture.coordinator.endNativeOperation(flushHostedHeights: true)

        // then — height and settlement committed together before the next delivery admits.
        #expect(box.height == 44)
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: true, revision: 0))
    }

    // MARK: pending pairs close a committed-settled gate

    @Test func givenCommittedSettledAdmission_whenHeldPendingReportArrives_thenGateClosesAndQueuedPublicationRevokes() async throws {
        // given — a settled, admitted row whose publication arrived through the actual queued
        // delivery, never a manual one.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.coordinator.seenIDs = ["task:first"]
        fixture.register(entries: [fixture.taskEntry(id: "first"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:first")])
        let cell = try #require(fixture.realizeCell(row: 0))
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.queueGeometry()
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == true }

        // when — a non-settled report for a changed height is recorded inside a native
        // operation, so its (height, settlement) pair is held pending.
        fixture.coordinator.beginNativeOperation()
        let generation = box.reportGeneration
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0.5, naturalHeight: 44, logicalTarget: 1, authorityGeneration: generation),
            box: box, cell: cell, generation: generation
        )

        // then — the pending pair closes the gate immediately, even though the committed
        // settled flag is still true: pending height is provisional until the atomic commit.
        #expect(fixture.coordinator.hasUnsettledPresentations)
        #expect(box.latestCombinedReport?.occupiedHeight == 22)
        fixture.coordinator.endNativeOperation(flushHostedHeights: true)

        // then — the standing admission is revoked by the actual queued publication.
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == false }
        #expect(box.height == 22)
        #expect(!box.presentationSettled)
    }

    // MARK: same-height settlement transition queues its own re-evaluation

    @Test func givenMarkedFreshAssociation_whenSettledReportRepeatsCommittedHeight_thenQueuedPublicationAdmitsWithoutManualDelivery() async throws {
        // given — a fresh marked association whose committed height already equals the
        // settled endpoint (provisional full slot, presentation still unsettled).
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "fresh"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:fresh")])
        let cell = fixture.controlledReportingCell(for: box)
        fixture.coordinator.queueGeometry()
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == false }
        #expect(box.height == 44)
        #expect(fixture.coordinator.hasUnsettledPresentations)
        #expect(fixture.coordinator.pendingHostedHeights.isEmpty)

        // when — the settled endpoint repeats the already-committed height: a same-height
        // settlement transition with an empty pending set.
        let generation = box.reportGeneration
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1, authorityGeneration: generation),
            box: box, cell: cell, generation: generation
        )

        // then — the gate cleared AND the actual queued delivery admitted true without any
        // manual geometry delivery; pendingHostedHeights never held work to flush.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        #expect(box.pendingHostedHeight == nil)
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == true }
        #expect(fixture.historyPublications.count == 2)
    }

    // MARK: refresh authority — same height still confirms current authority; stale is ignored

    @Test func givenRefreshedAuthority_whenReportRepeatsCommittedHeight_thenCurrentAuthorityConfirmsAndStalePendingNeverCommits() throws {
        // given — a marked zero-start row with an in-flight mid-presentation report.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "refreshed"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:refreshed")])
        let cell = try #require(fixture.realizeCell(row: 0))
        fixture.coordinator.beginNativeOperation()
        let staleGeneration = box.reportGeneration
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0.5, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: staleGeneration),
            box: box, cell: cell, generation: staleGeneration
        )

        // when — the root refresh supersedes the report authority, then the boundary flushes.
        fixture.coordinator.refresh(box)
        fixture.coordinator.endNativeOperation(flushHostedHeights: true)

        // then — the stale pending height (22) never commits; the gate keeps holding.
        #expect(box.height == 44)
        #expect(fixture.coordinator.hasUnsettledPresentations)

        // when — a stale-generation callback arrives after the refresh.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: staleGeneration),
            box: box, cell: cell, generation: staleGeneration
        )
        #expect(fixture.coordinator.hasUnsettledPresentations)
        // The rejected-generation flush cleared the stale pending fields, so the pending
        // gate cannot hold admission for an authority that will never commit.
        #expect(box.pendingHostedHeight == nil)
        #expect(box.pendingHostedSettlement == false)

        // when — the current authority repeats the already-committed height.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: box.reportGeneration),
            box: box, cell: cell, generation: box.reportGeneration
        )

        // then — the repeated same-height report still confirms the CURRENT authority.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        #expect(box.height == 44)
    }

    // MARK: detach restores the native slot before admission

    @Test func givenUnsettledAssociation_whenCellDetaches_thenNaturalSlotRestoresBeforeTrueAdmission() async throws {
        // given — a marked row with a committed provisional height admitted false.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "detached"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:detached")])
        let cell = try #require(fixture.realizeCell(row: 0))
        let generation = box.reportGeneration
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0.5, naturalHeight: 44, logicalTarget: 1, authorityGeneration: generation),
            box: box, cell: cell, generation: generation
        )
        #expect(box.height == 22)
        #expect(fixture.coordinator.hasUnsettledPresentations)
        fixture.coordinator.queueGeometry()
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == false }

        // when — the association detaches (scroll offscreen, reuse, removal or teardown).
        fixture.coordinator.disassociate(box)

        // then — the blocker retires and the hosted evidence clears, but the stale native
        // slot holds admission until the queued native-safe boundary restores it.
        #expect(box.latestHostedReport == nil)
        #expect(box.height == nil)
        #expect(box.pendingHostedHeight == nil)
        #expect(fixture.coordinator.hasUnsettledPresentations)
        await waitUntil(timeout: 5) { !fixture.coordinator.hasUnsettledPresentations }

        // then — the static natural estimate restored BEFORE true admission, which follows
        // from the same queued delivery — never a manual geometry call.
        let restored = try #require(box.height)
        #expect(restored > HfRadius.Metrics.hairlineStroke)
        await waitUntil(timeout: 5) { fixture.historyPublications.last?.visible == true }
        #expect(box.height == restored)

        // when — a stale callback from the retired association arrives after restoration.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 0.5, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: box.reportGeneration),
            box: box, cell: cell, generation: box.reportGeneration
        )

        // then — the retired association is ignored: it cannot re-mark, re-commit or disturb
        // the restored natural slot.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        #expect(box.height == restored)
    }

    // MARK: non-animated rows settle immediately

    @Test func givenPreviouslySeenItem_whenRealizedNonAnimated_thenNoBlockerAndSettledGeometryAdmitsImmediately() throws {
        // given — a previously seen task row: its disclosure realizes appeared, not animated.
        let fixture = SettlementFixture()
        defer { fixture.close() }
        fixture.coordinator.seenIDs = ["task:seen"]
        fixture.register(entries: [fixture.taskEntry(id: "seen"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:seen")])
        let cell = try #require(fixture.realizeCell(row: 0))
        #expect(cell.animate == false)

        // when — the settled presentation report commits.
        fixture.coordinator.recordHostedPresentation(
            .settlement(progress: 1, naturalHeight: 44, logicalTarget: 1,
                        authorityGeneration: box.reportGeneration),
            box: box, cell: cell, generation: box.reportGeneration
        )

        // then — no blocker ever existed and geometry is settled immediately.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        #expect(box.height == 44)
        fixture.coordinator.deliverGeometry()
        #expect(fixture.historyPublications == [SettlementAdmission(visible: true, revision: 0)])
    }

    // MARK: reduce motion settles through authoritative geometry

    @Test func givenReduceMotionOverride_whenItemRealizes_thenNoBridgeBlockerAndGeometryCommitsSettled() throws {
        // given — Reduce Motion is forced on, disabling the disclosure presentation bridge.
        let fixture = SettlementFixture(reduceMotion: true)
        defer { fixture.close() }
        fixture.register(entries: [fixture.taskEntry(id: "motion"), fixture.sentinelEntry()],
                         heights: [44, HfRadius.Metrics.hairlineStroke])
        let box = try #require(fixture.coordinator.boxesByID[.init(logicalID: "task:motion")])
        _ = try #require(fixture.realizeCell(row: 0))

        // when — the authoritative geometry report commits through the non-bridged channel.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        let cell = try #require(fixture.coordinator.cells[box.entry.displayID])
        fixture.coordinator.recordHostedHeight(48, box: box, cell: cell, generation: box.reportGeneration)

        // then — no blocker ever existed and native geometry settled at the reported height.
        #expect(!fixture.coordinator.hasUnsettledPresentations)
        #expect(box.height == 48)
        fixture.coordinator.deliverGeometry()
        #expect(box.height == 48)
        #expect(fixture.historyPublications.last == SettlementAdmission(visible: true, revision: 0))
    }

    // MARK: root refresh re-emits an identical endpoint

    @Test func givenRootRefreshWithIdenticalEndpoint_whenReportAuthorityRenews_thenPreferenceChannelReemits() async throws {
        // given — a settled non-animated disclosure hosted directly, reporting through the
        // combined presentation channel with a captured reporting authority.
        _ = NSApplication.shared
        let probe = PresentationProbeState()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: PresentationProbe(state: probe, authority: 7))
        host.frame = CGRect(x: 0, y: 0, width: 320, height: 240)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return !probe.reports.isEmpty
        }
        let first = try #require(probe.reports.last)
        #expect(first.progress == 1)
        #expect(first.logicalTarget == 1)
        #expect(first.isSettled)
        #expect(first.authorityGeneration == 7)

        // when — the cell's root is refreshed with IDENTICAL geometry; only the reporting
        // authority generation renewed (exactly what refresh/association reconfiguration does).
        host.rootView = PresentationProbe(state: probe, authority: 8)
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return probe.reports.contains { $0.authorityGeneration == 8 }
        }

        // then — the identical endpoint re-emitted under the current authority; without the
        // authority in the combined value, preference equality would have suppressed it and
        // the refreshed root's endpoint would never have been recorded.
        let reemitted = try #require(probe.reports.last { $0.authorityGeneration == 8 })
        #expect(reemitted.progress == first.progress)
        #expect(reemitted.naturalHeight == first.naturalHeight)
        #expect(reemitted.logicalTarget == first.logicalTarget)
    }
}

/// A settled disclosure's report sink for hosting the bridge directly: every combined report
/// the preference channel emits, including authority-only value changes after a root refresh.
@MainActor
private final class PresentationProbeState {
    var reports: [SidebarNativePresentationReport] = []
}

/// Hosts one disclosure root directly, overriding Reduce Motion off so the bridged,
/// reporting branch runs deterministically in a never-fronted window.
private struct PresentationProbe: View {
    let state: PresentationProbeState
    let authority: Int

    var body: some View {
        SidebarDisclosureRow(isVisible: true, animate: false,
                            reportAuthority: authority,
                            onPresentation: { report in state.reports.append(report) }) {
            Text("Deterministic disclosure content").frame(width: 280, height: 44)
        }
        .environment(\.hfReduceMotionOverride, false)
    }
}

/// A fully deterministic native fixture: a window-attached scroll/outline pair whose hosting
/// views are never laid out, so no SwiftUI disclosure animation or timer participates. Every
/// state change is driven synchronously through the coordinator's recording and delivery
/// boundaries.
@MainActor
private final class SettlementFixture {
    let coordinator = SidebarNativeList.Coordinator()
    let window: NSWindow
    let scroll: NSScrollView
    let outline: SidebarOwnedOutlineView
    private(set) var historyPublications: [SettlementAdmission] = []

    init(reduceMotion: Bool = false, width: Double = 320, height: Double = 240) {
        _ = NSApplication.shared
        self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        self.scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.contentView.frame = scroll.bounds
        self.outline = SidebarOwnedOutlineView(frame: CGRect(x: 0, y: 0, width: width, height: height))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("SidebarPresentationSettlement"))
        column.width = width
        outline.addTableColumn(column)
        scroll.documentView = outline
        window.contentView = scroll
        coordinator.install(scroll: scroll, outline: outline)
        var environment = EnvironmentValues()
        environment.hfReduceMotionOverride = reduceMotion
        coordinator.environment = environment
        let input = SidebarListPresentation(
            sections: [SidebarSection(bucket: .today, items: [])], workflowTitles: [], workflowsExpanded: true,
            banner: nil, listError: nil, skeleton: false, taskHistory: HistoryLoadingState(),
            workflowHistory: HistoryLoadingState(), emptyMessage: nil, fadingIDs: [],
            minimumRowHeight: 0, historyRevision: 0, historyToken: "presentation-settlement"
        )
        coordinator.input = input
        coordinator.appliedInput = input
        coordinator.actions.history = { [weak self] visible, revision in
            self?.historyPublications.append(SettlementAdmission(visible: visible, revision: revision))
        }
    }

    /// A task row entry whose lookup key is the given id.
    func taskEntry(id: String) -> SidebarListEntry {
        let row = TaskRowModel(id: id, backend: "codex", title: "A disclosure row with enough content to measure",
                               status: .completed, repoName: "repo", ageText: "1h")
        return SidebarListEntry(id: "task:\(id)", content: .item(.task(row)))
    }

    /// The bounded-pagination sentinel row.
    func sentinelEntry() -> SidebarListEntry {
        SidebarListEntry(id: "history:sentinel", content: .sentinel)
    }

    /// Registers rows with committed heights, replacing any previous rows.
    func register(entries: [SidebarListEntry], heights: [CGFloat]) {
        let boxes = entries.map(SidebarNativeItemBox.init)
        for (index, box) in boxes.enumerated() { box.height = heights[index] }
        coordinator.boxes = boxes
        coordinator.boxesByID = Dictionary(uniqueKeysWithValues: boxes.map { ($0.entry.displayID, $0) })
        coordinator.indexesByID = Dictionary(uniqueKeysWithValues:
            boxes.enumerated().map { ($1.entry.displayID, $0) })
        outline.reloadData()
    }

    /// Realizes a cell through AppKit's own row machinery, exactly as production does.
    func realizeCell(row: Int) -> SidebarNativeCell? {
        outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? SidebarNativeCell
    }

    /// A deterministic report source for the same-height queue test. It has an owned native
    /// attachment but no SwiftUI producer or prominence callbacks that could emit a second
    /// independently animated source while this test injects the recorded endpoint sequence.
    func controlledReportingCell(for box: SidebarNativeItemBox) -> SidebarNativeCell {
        let cell = SidebarNativeCell(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        box.reportGeneration += 1
        box.associationToken = UUID()
        box.presentationSettled = false
        cell.association = box
        coordinator.cells[box.entry.displayID] = cell
        window.contentView = cell
        return cell
    }

    /// Appends an unseen fresh item row ahead of the sentinel and returns its box.
    func insertFreshItem(id: String) -> SidebarNativeItemBox? {
        var entries = coordinator.boxes.map(\.entry)
        var heights = coordinator.boxes.map { $0.height ?? HfRadius.Metrics.hairlineStroke }
        entries.insert(taskEntry(id: id), at: entries.count - 1)
        heights.insert(44, at: heights.count - 1)
        register(entries: entries, heights: heights)
        return coordinator.boxesByID[.init(logicalID: "task:\(id)")]
    }

    /// Commits one row's height into the native geometry.
    func noteRowHeight(_ row: Int) {
        outline.noteHeightOfRows(withIndexesChanged: IndexSet(integer: row))
    }

    func close() {
        window.contentView = nil
        window.close()
    }
}

private extension SidebarNativePresentationReport {
    /// Reports one presentation state with its progress, natural height, logical target and
    /// the reporting authority generation it was recorded under.
    static func settlement(progress: CGFloat, naturalHeight: CGFloat, logicalTarget: CGFloat,
                           authorityGeneration: Int) -> Self {
        .init(progress: progress, naturalHeight: naturalHeight, logicalTarget: logicalTarget,
              authorityGeneration: authorityGeneration)
    }
}

private struct SettlementAdmission: Equatable {
    let visible: Bool
    let revision: Int
}
