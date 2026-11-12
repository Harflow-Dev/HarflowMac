import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ActivityPromptSurfaceTests {
    @Test(arguments: ["detail", "parallel", "workflow"])
    func givenStartedPrompt_whenHostingActivitySurface_thenOnlyItsPromptOwnerDisplaysIt(surface: String) async throws {
        // given — a three-line prompt makes the bubble distinguishable from the compact start line.
        _ = NSApplication.shared
        let prompt = "First line of initial assignment\nSecond line of initial assignment\nThird line of initial assignment"
        let task = try #require(TaskInfo(.object([
            "task_id": .string("prompt-fixture"), "backend": .string("codex"), "status": .string("completed")
        ])))
        let row = ConversationTimelineRow(id: "started", taskID: task.id, timestamp: nil,
            kind: .item(PreviewFixtures.startedItem(prompt: prompt)), live: false)
        let state = ParallelColumnUIState()
        func root(showPrompt: Bool) -> AnyView {
            if surface == "detail" {
                return AnyView(TimelinePaneView(model: TimelinePaneModel(stepCountText: "1 activity item", rows: [row],
                    start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)))
            }
            let column = ParallelColumnModel(id: task.id, task: task, title: "Prompt fixture", subtitle: "Codex",
                isBusy: false, outcomeMessage: nil, showPrompt: showPrompt,
                rows: [row], activityRows: ActivityRowsBuilder.build(from: [row]), liveStep: nil,
                isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
            if surface == "workflow" {
                return AnyView(WorkflowActivityColumns(columns: [column], selectedTaskID: nil))
            }
            return AnyView(GeometryReader { geometry in
                ScrollView(.horizontal) {
                    ParallelColumnsContent(columns: [column], availableSize: geometry.size,
                        stateForColumn: { _ in state }, onViewport: { _, _ in })
                }
            })
        }
        let host = NSHostingView(rootView: root(showPrompt: false))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        // when
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host)
.compactMap { $0 as? NSScrollView }
                .contains { $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > 30 }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        let document = try #require(scroll.documentView)
        // then — detail owns the started-row bubble; Parallel's feed stays compact.
        if surface == "detail" {
            #expect(document.bounds.height > 100)
        } else {
            try await verifyCompactSurface(host: host, scroll: scroll, document: document,
                                           togglePrompt: { host.rootView = root(showPrompt: true) })
        }
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func mountedMeasurementFrames(in document: NSView) -> [CGRect] {
        descendants(document)
            .compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.width > 0 && $0.height > 0 }
    }

    /// A lane or workflow activity feed draws no prompt bubble of its own: its rows stay compact, and turning View prompt on
    /// without a stored request (the request block is drawn from a stored read, not from the started row) changes nothing.
    private func verifyCompactSurface(host: NSView, scroll: NSScrollView, document: NSView,
                                      togglePrompt: () -> Void) async throws {
        await waitUntil(timeout: 3) {
            host.layoutSubtreeIfNeeded()
            return !mountedMeasurementFrames(in: document).isEmpty
        }
        let mountedRows = mountedMeasurementFrames(in: document)
        #expect(!mountedRows.isEmpty)
        #expect(mountedRows.allSatisfy { $0.width > 0 && $0.height > 0 && $0.height < 100 },
                "The activity rows must retain compact mounted content geometry")
        let viewport = scroll.contentView.bounds.height
        togglePrompt()
        await waitUntil { host.layoutSubtreeIfNeeded(); return true }
        for _ in 0 ..< 10 { host.layoutSubtreeIfNeeded(); await Task.yield() }
        #expect(scroll.contentView.bounds.height == viewport, "View prompt without a stored request adds nothing above the feed")
        #expect(mountedMeasurementFrames(in: document).allSatisfy { $0.height < 100 })
    }
}
