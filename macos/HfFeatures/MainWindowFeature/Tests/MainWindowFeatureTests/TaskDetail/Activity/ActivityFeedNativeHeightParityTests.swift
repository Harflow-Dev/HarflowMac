//
//  ActivityFeedNativeHeightParityTests.swift
//  MainWindowFeatureTests
//
//  Native Task Activity height parity. Each test drives the real feed in an ordered-front window
//  and compares, for every realized row, three heights: the table
//  slot, the in-window natural height of the displayed hosted root, and the off-window measurement
//  the coordinator caches. A slot shorter than the displayed root clips that row; on the last row
//  or the tail it clips the bottom of the feed. The tests use synthetic fixtures only and settle
//  through the window's display cycle rather than forced layout.
//

import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
@testable import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeHeightParityTests {

    // MARK: - Rich Markdown same-height revision

    @Test func givenStreamingRichMarkdown_whenSameHeightRevisionsFollow_thenEverySlotMatchesItsDisplayedRoot() async throws {
        for width in [CGFloat(420), 640] {
            // given — a live, following feed whose newest row streams rich Markdown.
            _ = NSApplication.shared
            let fixture = NativeHeightParityFixture(width: width)
            let snapshots = NativeHeightParityFixture.richSnapshots()
            var markdown: [String: StreamingMarkdownState] = [:]
            var rows = fixture.richRows(text: snapshots[0], live: true, streaming: true)
            markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: markdown)
            let mounted = fixture.mount(fixture.feed(rows: rows, markdown: markdown))
            defer { mounted.tearDown() }
            let initial = try await mounted.settle(changing: NativeHeightParityFixture.richID, after: -1)

            // when — the row grows through every snapshot, then receives revisions that change
            // only the streaming overlay (caret → "(incomplete)" → none), whose height is fixed.
            var revision = initial
            var steps: [(label: String, rows: [ConversationTimelineRow])] = snapshots.dropFirst().enumerated().map { index, text in
                ("grow-\(index + 1)", fixture.richRows(text: text, live: true, streaming: true))
            }
            steps.append(("same-height-live-off", fixture.richRows(text: snapshots.last!, live: false, streaming: true)))
            steps.append(("same-height-finalized", fixture.richRows(text: snapshots.last!, live: false, streaming: false)))
            for step in steps {
                rows = step.rows
                markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: markdown)
                mounted.rootView = fixture.feed(rows: rows, markdown: markdown)
                revision = try await mounted.settle(changing: NativeHeightParityFixture.richID, after: revision)

                // then — every realized slot equals what its root draws, the off-window
                // measurement agrees with the in-window layout, and the live bottom is visible.
                let report = try mounted.parity(label: "rich w=\(Int(width)) \(step.label)")
                for row in report.rows {
                    #expect(abs(row.drawn - row.slot) <= 1,
                            "w=\(Int(width)) \(step.label) \(row.id): slot \(row.slot) != drawn \(row.drawn) (current=\(row.current))")
                    #expect(abs(row.offWindow - row.drawn) <= 1,
                            "w=\(Int(width)) \(step.label) \(row.id): off-window measurement \(row.offWindow) != drawn \(row.drawn)")
                    #expect(abs((row.cached ?? -1) - row.slot) <= 1,
                            "w=\(Int(width)) \(step.label) \(row.id): cached height \(row.cached ?? -1) != slot \(row.slot)")
                    #expect(row.current, "w=\(Int(width)) \(step.label) \(row.id): displayed host must contain the committed entry")
                }
                #expect(report.following, "w=\(Int(width)) \(step.label): live follow must stay on")
                #expect(report.bottomGap <= 1, "w=\(Int(width)) \(step.label): document bottom \(report.bottomGap)pt below viewport")
                #expect(report.lastContentOverflow <= 1,
                        "w=\(Int(width)) \(step.label): last row draws \(report.lastContentOverflow)pt below the viewport")
            }
        }
    }

    // MARK: - Tail and queued messages

    @Test func givenFollowingFeed_whenTailAndQueueChangeInPlace_thenTailSlotMatchesItsDisplayedRoot() async throws {
        // given — a following feed with settled rich content and no tail.
        _ = NSApplication.shared
        let fixture = NativeHeightParityFixture(width: 420)
        let rows = fixture.richRows(text: NativeHeightParityFixture.richSnapshots().last!, live: true, streaming: false)
        let markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: [:])
        let mounted = fixture.mount(fixture.feed(rows: rows, markdown: markdown))
        defer { mounted.tearDown() }
        _ = try await mounted.settle(changing: NativeHeightParityFixture.richID, after: -1)

        let pending = PendingMessage(id: "native-height-pending", text: NativeHeightParityFixture.longMessage("Pending"))
        let queued = WorkMessageBubble(id: "native-height-queued", seq: 1, kind: .queued(canCancel: true, note: nil),
                                       text: NativeHeightParityFixture.longMessage("Queued"))
        let undeliverable = WorkMessageBubble(id: "native-height-undeliverable", seq: 2, kind: .undeliverable("The task ended first."),
                                              text: "An earlier note that was not delivered.")
        func standard(work: [WorkMessageBubble], line: String, cancel: ActivityFeedTailPresentation.CancelAvailability)
            -> ActivityFeedTailPresentation {
            .standard(.init(pendingMessages: [pending], workMessages: work,
                            liveStep: .init(text: line, indicator: .singleDot), cancel: cancel))
        }
        let tailValue = ActivityFeedTail(pendingMessages: [pending])
        // when — each step changes the tail entry without changing the row set; the disclosure
        // step grows the displayed root through local observable state with the model unchanged,
        // and the step after it is a same-height revision on top of that growth.
        let steps: [(label: String, tail: ActivityFeedTailPresentation, disclose: Bool)] = [
            ("pending-appears", standard(work: [], line: "Reading files 1", cancel: .enabled), false),
            ("queued-appears", standard(work: [queued, undeliverable], line: "Reading files 1", cancel: .enabled), false),
            ("cancel-disabled", standard(work: [queued, undeliverable], line: "Reading files 1", cancel: .disabled), false),
            ("live-step-same-length", standard(work: [queued, undeliverable], line: "Reading files 2", cancel: .disabled), false),
            ("queued-expanded", standard(work: [queued, undeliverable], line: "Reading files 2", cancel: .disabled), true),
            ("same-height-after-expand", standard(work: [queued, undeliverable], line: "Reading files 3", cancel: .disabled), false)
        ]
        var revision = -1
        for step in steps {
            if step.disclose {
                mounted.state.disclosures.expandedPrompts.insert(queued.id)
                try await mounted.settleHostedGrowth(id: NativeHeightParityFixture.tailID)
            } else {
                mounted.rootView = fixture.feed(rows: rows, markdown: markdown, tailValue: tailValue, tail: step.tail)
                revision = try await mounted.settle(changing: NativeHeightParityFixture.tailID, after: revision)
            }

            // then — the tail slot equals the tail root's displayed height and ends in the viewport.
            let report = try mounted.parity(label: "tail \(step.label)")
            let tail = try #require(report.rows.first { $0.id == NativeHeightParityFixture.tailID }, "tail must be realized at \(step.label)")
            #expect(abs(tail.drawn - tail.slot) <= 1, "\(step.label): tail slot \(tail.slot) != drawn \(tail.drawn)")
            #expect(abs(tail.offWindow - tail.drawn) <= 1, "\(step.label): tail off-window \(tail.offWindow) != drawn \(tail.drawn)")
            #expect(abs((tail.cached ?? -1) - tail.slot) <= 1,
                    "\(step.label): tail cached height \(tail.cached ?? -1) != slot \(tail.slot)")
            #expect(tail.current, "\(step.label): tail host must contain the committed entry")
            #expect(report.following, "\(step.label): live follow must stay on")
            #expect(report.bottomGap <= 1, "\(step.label): document bottom \(report.bottomGap)pt below viewport")
            #expect(report.lastContentOverflow <= 1, "\(step.label): tail draws \(report.lastContentOverflow)pt below the viewport")
        }
    }

    @Test func givenQueuedPrompt_whenCollapsedAndExpandedAtResponsiveWidths_thenNativeHeightMatchesMeasurement() async throws {
        for width in [CGFloat(320), 560, 900] {
            _ = NSApplication.shared
            let fixture = NativeHeightParityFixture(width: width)
            let rows = fixture.richRows(text: "The activity result is ready.", live: false, streaming: false)
            let markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: [:])
            let queued = WorkMessageBubble(
                id: "native-height-responsive-queued-\(Int(width))", seq: 1,
                kind: .queued(canCancel: true, note: NativeHeightParityFixture.longMessage("Queued note")),
                text: NativeHeightParityFixture.longMessage("Queued prompt")
            )
            var withoutNote = queued
            withoutNote.kind = .queued(canCancel: true, note: nil)
            let mounted = fixture.mount(fixture.feed(rows: rows, markdown: markdown))
            defer { mounted.tearDown() }
            _ = try await mounted.settle(changing: NativeHeightParityFixture.richID, after: -1)
            let baseline = try mounted.parity(label: "queue absent w=\(Int(width))")
            #expect(!baseline.rows.contains { $0.id == NativeHeightParityFixture.tailID })

            // Each production rendering branch must add real height before disclosure expands it.
            let stages: [(WorkMessageBubble, ActivityFeedTailPresentation.CancelAvailability)] = [
                (withoutNote, .hidden), (queued, .hidden), (queued, .enabled)
            ]
            var revision = -1
            var collapsedHeight: CGFloat = 0
            for (message, cancel) in stages {
                let tail = ActivityFeedTailPresentation.standard(.init(workMessages: [message], cancel: cancel))
                mounted.rootView = fixture.feed(rows: rows, markdown: markdown, tail: tail)
                revision = try await mounted.settle(changing: NativeHeightParityFixture.tailID, after: revision)
                let row = try mounted.responsiveTail(expected: message, cancel: cancel, label: "queued w=\(Int(width))")
                #expect(row.drawn > collapsedHeight + 10, "Queue insertion, note and Cancel must each add rendered height")
                collapsedHeight = row.drawn
            }

            mounted.state.disclosures.expandedPrompts.insert(queued.id)
            try await mounted.settleHostedGrowth(id: NativeHeightParityFixture.tailID)
            let expanded = try mounted.responsiveTail(expected: queued, cancel: .enabled, label: "expanded w=\(Int(width))")
            #expect(expanded.drawn > collapsedHeight)
        }
    }

    // MARK: - Viewport resize

    @Test func givenFollowingRichFeed_whenViewportShrinksAndGrows_thenLiveBottomStaysVisible() async throws {
        // given — the composer growing or shrinking changes only the feed's viewport height.
        _ = NSApplication.shared
        let fixture = NativeHeightParityFixture(width: 420)
        let rows = fixture.richRows(text: NativeHeightParityFixture.richSnapshots().last!, live: true, streaming: true)
        let markdown = ActivityRowsBuilder.markdownSnapshot(from: rows, previous: [:])
        let mounted = fixture.mount(fixture.feed(rows: rows, markdown: markdown))
        defer { mounted.tearDown() }
        _ = try await mounted.settle(changing: NativeHeightParityFixture.richID, after: -1)

        for height in [CGFloat(330), 450, 300, 450] {
            // when
            mounted.rootView = fixture.feed(rows: rows, markdown: markdown, height: height)
            await mounted.settleViewport(height: height)

            // then
            let report = try mounted.parity(label: "viewport h=\(Int(height))")
            #expect(abs(report.viewportHeight - height) <= 1, "viewport must reach \(height), got \(report.viewportHeight)")
            #expect(report.following, "h=\(Int(height)): live follow must stay on")
            #expect(report.bottomGap <= 1, "h=\(Int(height)): document bottom \(report.bottomGap)pt below viewport")
            #expect(report.lastContentOverflow <= 1, "h=\(Int(height)): last row draws \(report.lastContentOverflow)pt below the viewport")
        }
    }

}

// MARK: - NativeHeightParityFixture

@MainActor private struct NativeHeightParityFixture {
    static let richID = "t1#2"
    static let tailID = "activity-feed-tail"
    let width: CGFloat

    static func richSnapshots() -> [String] {
        let sections = [
            "## Root cause",
            "The store is read **before** it is warmed, so a cold keychain returns `nil` and the login "
                + "flow retries with a stale token that wraps across several lines in the reading column.",
            "- The first finding keeps the row tall and mentions `KeychainStore.read(_:)` inline.\n"
                + "- A second finding wraps across the narrow reading column with **emphasis** and more prose.\n"
                + "- A third finding is short.",
            "```swift\nlet warmed = try await store.warm()\nlet value = warmed ? store.read(key) : nil\nreturn value\n```",
            "| File | Change |\n|---|---|\n| `KeychainStore.swift` | warm before read, keeping the cache coherent |\n"
                + "| `LoginTests.swift` | regression test that fails without the fix |",
            "> Verified on macOS 26 only; the cold path needs a fresh simulator keychain to reproduce reliably.",
            "1. Reproduce with a cold keychain\n2. Warm, then read, and check the token is current\n3. Ship",
            "The final paragraph keeps growing while the response streams, so the live bottom has to follow it."
        ]
        return (2 ... sections.count).map { sections.prefix($0).joined(separator: "\n\n") }
    }

    static func longMessage(_ label: String) -> String {
        "\(label): " + String(repeating: "Please check the evidence before continuing and keep the change scoped. ", count: 5)
    }

    func richRows(text: String, live: Bool, streaming: Bool, seq: Int = 2) -> [ConversationTimelineRow] {
        let lead = seq == 2 ? [ActivityFixture.text(1, "Looking at the failing login test.")] : []
        return lead + [ActivityFixture.row(seq, live: live, .text(text, streaming: streaming))]
    }

    func historyRows() -> [ConversationTimelineRow] {
        (1 ... 24).map { seq in
            ActivityFixture.text(seq, "History paragraph \(seq) explains one earlier step of the investigation in a couple of lines.")
        }
    }

    func feed(rows: [ConversationTimelineRow], markdown: [String: StreamingMarkdownState],
              tailValue: ActivityFeedTail = ActivityFeedTail(), tail: ActivityFeedTailPresentation = .absent,
              height: CGFloat = 450) -> AnyView {
        AnyView(ActivityFeedNativeHeightParityRoot(rows: ActivityRowsBuilder.build(from: rows, markdown: markdown), tailValue: tailValue,
                                tail: tail, width: width, height: height))
    }

    func mount(_ root: AnyView) -> NativeHeightParityMounted {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: AnyView(root.environment(\.nativeHeightParityState, state)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return NativeHeightParityMounted(state: state, host: host, window: window)
    }
}

// MARK: - Feed root

/// The feed exactly as TaskDetail hosts it: 24pt horizontal padding, prompt bubbles shown.
private struct ActivityFeedNativeHeightParityRoot: View {
    let rows: [ActivityRow]
    let tailValue: ActivityFeedTail
    let tail: ActivityFeedTailPresentation
    let width: CGFloat
    let height: CGFloat
    @Environment(\.nativeHeightParityState) private var state

    var body: some View {
        if let state {
            ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false, tailValue: tailValue,
                             horizontalPadding: HfRadius.Metrics.spacing24, state: state, onLoadMore: nil,
                             tailPresentation: tail, onCancelQueuedMessage: { _ in })
                .frame(width: width, height: height)
                .frame(maxHeight: .infinity, alignment: .top)
        }
    }
}

private extension EnvironmentValues {
    @Entry var nativeHeightParityState: ParallelColumnUIState?
}

// MARK: - NativeHeightParityMounted

@MainActor private final class NativeHeightParityMounted {
    struct RowParity {
        let id: String
        let slot: CGFloat
        let drawn: CGFloat
        let offWindow: CGFloat
        let cached: CGFloat?
        let current: Bool
        let visible: Bool
    }

    struct Report {
        let rows: [RowParity]
        let following: Bool
        let bottomGap: CGFloat
        let lastContentOverflow: CGFloat
        let viewportHeight: CGFloat
    }

    let state: ParallelColumnUIState
    let host: NSHostingView<AnyView>
    let window: NSWindow

    init(state: ParallelColumnUIState, host: NSHostingView<AnyView>, window: NSWindow) {
        self.state = state
        self.host = host
        self.window = window
    }

    /// Re-installs the state environment on every root replacement so the feed keeps one owner.
    var rootView: AnyView {
        get { host.rootView }
        set { host.rootView = AnyView(newValue.environment(\.nativeHeightParityState, state)) }
    }

    func tearDown() {
        window.contentView = nil
        window.close()
    }

    func scroll() throws -> ActivityFeedNativeScrollView {
        try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeScrollView }.first)
    }

    func table() throws -> ActivityFeedNativeTableView {
        try #require(try scroll().documentView as? ActivityFeedNativeTableView)
    }

    func owner() throws -> ActivityFeedNativeList.Coordinator {
        try #require(try table().owner)
    }

    /// Waits for a committed revision of `id` and a quiet coordinator — no queued hosted-height
    /// flush or bottom re-pin — across two consecutive display cycles.
    func settle(changing id: String, after previous: Int) async throws -> Int {
        var revision = -1
        var quiet = 0
        await waitUntil(timeout: 5) {
            window.displayIfNeeded()
            guard let coordinator = try? self.owner() else { return false }
            revision = coordinator.boxes.first { $0.entry.id == id }?.revision ?? -1
            let settled = coordinator.positioned && state.viewportPositioned && revision > previous
                && !coordinator.hostedHeightFlushQueued && coordinator.pendingHostedHeights.isEmpty
                && !coordinator.bottomRepinQueued
            quiet = settled ? quiet + 1 : 0
            return quiet >= 2
        }
        try #require(revision > previous && quiet >= 2, "\(id) did not commit and settle after revision \(previous)")
        return revision
    }

    /// Waits for local hosted growth (no model change) to be reported, flushed and settled.
    func settleHostedGrowth(id: String) async throws {
        var quiet = 0
        await waitUntil(timeout: 5) {
            window.displayIfNeeded()
            guard let coordinator = try? self.owner() else { return false }
            let settled = !coordinator.hostedHeightFlushQueued && coordinator.pendingHostedHeights.isEmpty
                && !coordinator.bottomRepinQueued
            quiet = settled ? quiet + 1 : 0
            return quiet >= 3
        }
        try #require(quiet >= 3, "\(id) hosted growth did not settle")
    }

    func settleViewport(height: CGFloat) async {
        var quiet = 0
        await waitUntil(timeout: 5) {
            window.displayIfNeeded()
            guard let feedScroll = try? self.scroll(), let coordinator = try? self.owner() else { return false }
            let settled = abs(feedScroll.contentView.bounds.height - height) <= 1
                && !coordinator.hostedHeightFlushQueued && coordinator.pendingHostedHeights.isEmpty
                && !coordinator.bottomRepinQueued
            quiet = settled ? quiet + 1 : 0
            return quiet >= 2
        }
    }

    func responsiveTail(expected: WorkMessageBubble, cancel: ActivityFeedTailPresentation.CancelAvailability,
                        label: String) throws -> RowParity {
        let coordinator = try owner()
        let entry = try #require(coordinator.boxes.first { $0.entry.id == NativeHeightParityFixture.tailID }?.entry)
        guard case .tail(.standard(let standard), _) = entry else {
            Issue.record("Responsive queue must commit a standard production tail")
            throw NSError(domain: "ActivityFeedNativeHeightParityTests", code: 1)
        }
        #expect(standard.workMessages == [expected])
        #expect(standard.cancel == cancel)
        try #require(activityNativeVisibleTailHasRenderedContent(host), "Responsive queue must realize coherent, nonblank content")
        let report = try parity(label: label)
        let row = try #require(report.rows.first { $0.id == NativeHeightParityFixture.tailID })
        #expect(row.current && row.visible)
        #expect(abs(row.drawn - row.slot) <= 1)
        #expect(abs(row.offWindow - row.drawn) <= 1)
        #expect(abs((row.cached ?? -1) - row.slot) <= 1)
        #expect(report.following)
        #expect(report.bottomGap <= 1)
        return row
    }

    /// Slot, displayed and off-window heights for every realized row, plus the live bottom.
    func parity(label: String) throws -> Report {
        let owner = try owner()
        let table = try table()
        let scroll = try scroll()
        let visible = scroll.documentVisibleRect
        var rows: [RowParity] = []
        var lastContentMaxY: CGFloat = 0
        for (index, box) in owner.boxes.enumerated() {
            guard let cell = owner.cells[box.entry.id], cell.window != nil, let host = cell.host else { continue }
            let slot = table.rect(ofRow: index)
            let drawn = host.fittingSize.height
            let offWindow = owner.measure(box, width: owner.currentWidth) ?? -1
            let row = RowParity(id: box.entry.id, slot: slot.height, drawn: drawn, offWindow: offWindow, cached: box.height,
                                current: host.rootView.entry == box.entry, visible: slot.intersects(visible))
            rows.append(row)
            if box.entry.anchorID != nil { lastContentMaxY = max(lastContentMaxY, slot.minY + drawn) }
        }
        return Report(rows: rows, following: state.followLive.isFollowing,
                            bottomGap: table.bounds.maxY - visible.maxY,
                            lastContentOverflow: lastContentMaxY - visible.maxY,
                            viewportHeight: scroll.contentView.bounds.height)
    }
}
