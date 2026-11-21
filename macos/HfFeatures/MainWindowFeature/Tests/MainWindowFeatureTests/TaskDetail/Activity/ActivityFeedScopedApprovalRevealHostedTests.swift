import AppKit
@testable import MainWindowFeature
import MonitorCore
import QuartzCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityFeedScopedApprovalRevealHostedTests {
    @Test func givenSameRawIDAndStaleFirstScope_whenRevealsCompete_thenOnlyFreshScopeScrollsAndFocusesInOrder() async throws {
        let taskSource: ActivityFeedApprovalEntry.Source = .task("task-A")
        let runSource: ActivityFeedApprovalEntry.Source = .workflowRun("run-A")
        let taskToken = UUID()
        let runToken = UUID()
        let staleToken = UUID()
        let harness = ScopedApprovalRevealHarness(taskSource: taskSource, runSource: runSource,
                                                  taskToken: taskToken, runToken: runToken,
                                                  initialReveals: [scopedReveal(taskSource, token: staleToken)])
        let host = NSHostingView(rootView: AnyView(harness.view().frame(width: 420, height: 450)))
        harness.host = host
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        defer {
            window.contentView = nil
            window.close()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        let table = try await waitForScopedRevealTable(host, state: harness.state)
        let scroll = try #require(table.enclosingScrollView)
        let edge = try #require(scroll.subviews.first { $0.layer is CAGradientLayer })
        let maximumOffset = max(0, table.bounds.height - scroll.documentVisibleRect.height)
        activityNativeTestScroll(scroll, to: maximumOffset * 0.45)
        let visible = scroll.documentVisibleRect
        let remaining = table.isFlipped ? table.bounds.maxY - visible.maxY : visible.minY - table.bounds.minY
        #expect(remaining > 1, "The stale reveal is tested with real content remaining below the viewport")
        let actionBand = CGRect(x: visible.minX, y: visible.maxY - 16, width: visible.width, height: 16)
        let actionRows = table.rows(in: actionBand)
        let actionIndices = actionRows.location == NSNotFound ? 0 ..< 0
            : max(0, actionRows.location) ..< min(table.numberOfRows, NSMaxRange(actionRows))
        #expect(actionIndices.allSatisfy { index in
            if case .scopedApproval = harness.owner?.entries[index] { return false }
            return true
        }, "The fade viewport does not overlap an approval action row")
        let fadeVisible = await waitForScopedRevealState { !edge.isHidden }
        #expect(fadeVisible, "A stale task-scoped token does not suppress the fade above the document end")
        #expect(harness.events.isEmpty, "A stale source/token pair produces no scroll or focus acknowledgement")

        harness.reveals = [scopedReveal(taskSource, token: taskToken), scopedReveal(runSource, token: runToken)]
        harness.refresh()
        let completed = await waitForScopedRevealState { harness.events.count == 4 }
        #expect(completed, "Both exact source-scoped reveal handshakes complete")
        #expect(harness.events == [
            .scroll(taskSource, "shared-request", taskToken),
            .focus(taskSource, "shared-request", taskToken),
            .scroll(runSource, "shared-request", runToken),
            .focus(runSource, "shared-request", runToken)
        ], "The second source waits until the first source's exact focus token is acknowledged")
        #expect(harness.entries.map(\.id) == [
            "activity-scoped-approval-task-task-A-shared-request",
            "activity-scoped-approval-run-run-A-shared-request"
        ], "Duplicate raw request IDs remain distinct in the native document")
        let runIndex = try #require(harness.owner?.entries.firstIndex {
            $0.id == "activity-scoped-approval-run-run-A-shared-request"
        })
        #expect(table.rect(ofRow: runIndex).intersects(table.visibleRect),
                "The final source-qualified target is revealed in the native table")
    }

    private func waitForScopedRevealTable(_ host: NSView, state: ParallelColumnUIState) async throws -> ActivityFeedNativeTableView {
        let ready = await waitForScopedRevealState {
            state.viewportPositioned
                && host.subviews.contains { view in
                    scopedRevealDescendants(view).contains { $0 is ActivityFeedNativeTableView }
                }
        }
        #expect(ready, "The hosted native feed reaches its positioned state")
        return try #require(scopedRevealDescendants(host).compactMap { $0 as? ActivityFeedNativeTableView }.first)
    }

    private func waitForScopedRevealState(_ predicate: @MainActor () -> Bool) async -> Bool {
        for _ in 0 ..< 250 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return predicate()
    }

    private func scopedRevealDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(scopedRevealDescendants)
    }

    private func scopedReveal(_ source: ActivityFeedApprovalEntry.Source, token: UUID) -> ActivityFeedApprovalReveal {
        ActivityFeedApprovalReveal(source: source,
                                   reveal: CallerApprovalReveal(requestID: "shared-request", token: token))
    }
}

@MainActor private final class ScopedApprovalRevealHarness {
    private(set) var entries: [ActivityFeedApprovalEntry]
    var reveals: [ActivityFeedApprovalReveal]
    let state = ParallelColumnUIState()
    var events: [ScopedApprovalRevealEvent] = []
    weak var host: NSHostingView<AnyView>?

    init(taskSource: ActivityFeedApprovalEntry.Source, runSource: ActivityFeedApprovalEntry.Source,
         taskToken: UUID, runToken: UUID, initialReveals: [ActivityFeedApprovalReveal]) {
        self.entries = [
            Self.entry(source: taskSource, token: taskToken, taskID: "task-A"),
            Self.entry(source: runSource, token: runToken, taskID: "worker-A")
        ]
        self.reveals = initialReveals
    }

    var owner: ActivityFeedNativeList.Coordinator? {
        host.flatMap { descendants($0).compactMap { ($0 as? ActivityFeedNativeTableView)?.owner }.first }
    }

    func view() -> some View {
        let rows = (0 ..< 32).map { index in
            ActivityRow.single(ConversationTimelineRow(
                id: "reveal-row-\(index)", taskID: "task-A", timestamp: nil,
                kind: .item(PreviewFixtures.textItem("Activity row \(index)")), live: false))
        }
        var feed = ActivityFeedView(rows: rows, start: nil, history: EventHistoryState(hasMore: false), isLoading: false,
                                    state: state, onLoadMore: nil)
        feed.scopedApprovals = entries
        feed.scopedApprovalReveals = reveals
        feed.composerEdge = true
        feed.onScopedApprovalScrollAcknowledged = { [weak self] source, requestID, token in
            self?.events.append(.scroll(source, requestID, token))
            self?.reveals.removeAll { $0.source == source && $0.requestID == requestID && $0.token == token }
            self?.refresh()
        }
        feed.onScopedApprovalFocusAcknowledged = { [weak self] source, requestID, token in
            self?.events.append(.focus(source, requestID, token))
            guard let self, let index = entries.firstIndex(where: {
                $0.source == source && $0.card.id == requestID && $0.card.focusToken == token
            }) else { return }
            entries[index].card.focusToken = nil
            refresh()
        }
        return feed.environment(\.hfReduceMotionOverride, true).frame(width: 420, height: 450)
    }

    func refresh() { host?.rootView = AnyView(view().frame(width: 420, height: 450)) }

    private static func entry(source: ActivityFeedApprovalEntry.Source, token: UUID, taskID: String) -> ActivityFeedApprovalEntry {
        let request = CallerApprovalRequest(raw: [
            "request_id": .string("shared-request"), "task_id": .string(taskID), "tool_name": .string("Bash"),
            "cwd": .string("/workspace/repo"), "freedom": .string("write_in_repo"),
            "scope": .string("exact_action_once"), "disposition": .string("pending"), "delivery": .string("pending"),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("swift test")])])
        ])
        let card = CallerApprovalCardModel(request: request, action: CallerApprovalAction.build(request), pending: true,
                                           expanded: false, canRespond: true, notice: nil, submitting: false,
                                           focusToken: token)
        return ActivityFeedApprovalEntry(source: source, card: card)
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private enum ScopedApprovalRevealEvent: Equatable {
    case scroll(ActivityFeedApprovalEntry.Source, String, UUID)
    case focus(ActivityFeedApprovalEntry.Source, String, UUID)
}
