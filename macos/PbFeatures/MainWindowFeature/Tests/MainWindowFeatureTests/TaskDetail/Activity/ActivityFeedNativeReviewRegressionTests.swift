import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedNativeReviewRegressionTests {
    @Test func givenVisibleSemanticRowRemoved_whenGroupingIdentityChanges_thenSurvivingNextRowKeepsItsPhysicalOffset() async throws {
        let state = ParallelColumnUIState()
        let values = rows()
        let host = NSHostingView(rootView: feed(values, state: state))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 3) { state.viewportPositioned }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        let owner = try #require(table.owner)
        let first = try #require(owner.entries.firstIndex { $0.id == "review-5" })
        scroll.contentView.scroll(to: CGPoint(x: 0, y: table.rect(ofRow: first).minY + 20))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 3) { !state.followLive.isFollowing && physicalFrame("review-6", in: host) != nil }
        let before = try #require(physicalFrame("review-6", in: host)).minY - scroll.documentVisibleRect.minY
        var regrouped = values
        regrouped[5] = textRow(id: "regrouped-card", sequence: 50)
        host.rootView = feed(regrouped, state: state)
        await waitUntil(timeout: 3) {
            owner.entries.contains { $0.id == "regrouped-card" } && physicalFrame("review-6", in: host) != nil
        }
        let after = try #require(physicalFrame("review-6", in: host)).minY - scroll.documentVisibleRect.minY
        #expect(abs(after - before) < 3)
        #expect(!state.followLive.isFollowing)
    }

    @Test func givenFollowingFeed_whenUpAndHomeKeysNavigate_thenReadingPinsAndEndWithDownRearmsFollow() async throws {
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: feed(rows(), state: state))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        await waitUntil(timeout: 3) { state.viewportPositioned && state.followLive.isFollowing }
        let table = try #require(activityNativeDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        try sendKey("\u{F700}", code: 126, table: table, window: window)
        #expect(!state.followLive.isFollowing)
        #expect(state.retainedFirstID != nil)
        try sendKey("\u{F729}", code: 115, table: table, window: window)
        #expect(scroll.documentVisibleRect.minY < 3)
        #expect(!state.followLive.isFollowing)
        let beforeDown = scroll.documentVisibleRect.minY
        try sendKey("\u{F701}", code: 125, table: table, window: window)
        #expect(scroll.documentVisibleRect.minY > beforeDown)
        #expect(!state.followLive.isFollowing)
        try sendKey("\u{F72B}", code: 119, table: table, window: window)
        #expect(state.followLive.isFollowing)
        #expect(abs(table.bounds.maxY - scroll.documentVisibleRect.maxY) < 3)
    }

    @Test func givenRecycledPromptCell_whenConfiguredForToolAndTextIdentities_thenHostingStateAndNaturalGeometryAreFresh() throws {
        let actions = ActivityFeedNativeActions()
        let prompt = ActivityRow.single(ConversationTimelineRow(id: "review-prompt", taskID: "review-task", timestamp: nil,
            kind: .item(PreviewFixtures.startedItem(prompt: String(repeating: "A prompt with local show-more state.\n", count: 30))), live: false))
        let tool = try #require(ActivityRowsBuilder.build(from: [ActivityFixture.tool(1, path: "/a.swift")]).first)
        let cell = ActivityFeedNativeCell(frame: CGRect(x: 0, y: 0, width: 403, height: 450))
        let window = open(cell)
        defer { window.contentView = nil; window.close() }
        var hostIDs = Set<ObjectIdentifier>()
        for row in [prompt, tool, textRow(id: "review-recycled-text", sequence: 99)] {
            let entry = ActivityFeedNativeEntry.row(.init(row: row, isExpanded: false, fade: false, topSpacing: 12))
            let root = ActivityFeedNativeRowRoot(entry: entry, start: nil, horizontalPadding: 12,
                showsPromptBubble: true, environment: EnvironmentValues(), actions: actions, availableWidth: 403)
            cell.configure(root: root, id: entry.id)
            cell.layoutSubtreeIfNeeded()
            let host = try #require(cell.host)
            #expect(hostIDs.insert(ObjectIdentifier(host)).inserted)
            #expect(host.rootView.entry == entry)
            let measured = NSHostingView(rootView: root)
            measured.frame.size.width = 403
            #expect(abs(host.fittingSize.height - measured.fittingSize.height) < 3)
            #expect(host.fittingSize.height > 13)
        }
    }

    private func sendKey(_ character: String, code: UInt16, table: NSTableView, window: NSWindow) throws {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
        table.keyDown(with: event)
    }

    private func physicalFrame(_ id: String, in host: NSView) -> CGRect? {
        guard let cell = activityNativeDescendants(host)
.compactMap({ $0 as? ActivityFeedNativeCell })
            .first(where: { $0.entryID == id && $0.isCoherentNativeMeasurement }),
            let table = cell.enclosingScrollView?.documentView else { return nil }
        return cell.convert(cell.bounds, to: table)
    }

    private func rows() -> [ActivityRow] { (0 ..< 15).map { textRow(id: "review-\($0)", sequence: $0) } }

    private func textRow(id: String, sequence: Int) -> ActivityRow {
        .single(ConversationTimelineRow(id: id, taskID: "review-task", timestamp: nil,
            kind: .item(PreviewFixtures.textItem(String(repeating: "A natural review row wraps across the native reading width. ", count: 8),
                seq: sequence)), live: false))
    }

    private func feed(_ rows: [ActivityRow], state: ParallelColumnUIState) -> ActivityFeedView {
        ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(), isLoading: false,
                         horizontalPadding: 12, state: state, onLoadMore: nil)
    }

    private func open(_ host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }
}
