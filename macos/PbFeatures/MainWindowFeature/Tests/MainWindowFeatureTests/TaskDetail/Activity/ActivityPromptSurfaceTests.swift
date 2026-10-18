import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
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
                return AnyView(TimelinePaneView(model: TimelinePaneModel(stepCountText: "1 step", rows: [row],
                    start: nil, emptyText: nil, subTaskStrip: nil, isLoading: false)))
            }
            let column = ParallelColumnModel(id: task.id, task: task, title: "Prompt fixture", subtitle: "Codex",
                isBusy: false, outcomeMessage: nil, showPrompt: showPrompt, prompt: prompt,
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

    private func verifyCompactSurface(host: NSView, scroll: NSScrollView, document: NSView,
                                      togglePrompt: () -> Void) async throws {
        await waitUntil(timeout: 3) {
            host.layoutSubtreeIfNeeded()
            return mountedMeasurementFrames(in: document).count == 1
        }
        let mountedRows = mountedMeasurementFrames(in: document)
        let native = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.map {
            "id=\($0.entryID ?? "nil") cell=\($0.frame) host=\(String(describing: $0.host?.frame)) natural=\($0.host?.fittingSize.height ?? -1)"
        }
.joined(separator: "; ")
        #expect(mountedRows.count == 1, Comment(rawValue: "The compact activity surface must mount exactly its activity row: \(native)"))
        #expect(mountedRows.allSatisfy { $0.width > 0 && $0.height > 0 && $0.height < 100 },
                "The parallel activity row must retain compact mounted content geometry")
        let hiddenViewport = scroll.contentView.bounds.height
        togglePrompt()
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return scroll.contentView.bounds.height < hiddenViewport - 50
        }
        #expect(scroll.contentView.bounds.height < hiddenViewport - 50)
        let toggledRows = mountedMeasurementFrames(in: document)
        #expect(toggledRows.count == 1, "Toggling the prompt must not add an activity row")
        #expect(toggledRows.allSatisfy { $0.width > 0 && $0.height > 0 && $0.height < 100 },
                "The activity row must remain compact after the prompt moves to the header")
    }
}
