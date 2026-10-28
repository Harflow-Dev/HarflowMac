import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ParallelColumnLayoutTests {
    @Test(arguments: [0, 2, 6, 12])
    func givenShortOrWindowedHistory_whenHostedInsideParallelCells_thenActivityFillsSpaceAboveTheColumnComposer(count: Int) async throws {
        // given
        _ = NSApplication.shared
        let task = try #require(TaskInfo(.object([
            "task_id": .string("height-fixture"), "backend": .string("codex"),
            "status": .string("completed"), "repo_path": .string("/tmp")
        ])))
        let rows = (0 ..< count).map {
            ConversationTimelineRow(id: "row\($0)", taskID: task.id, timestamp: nil,
                                    kind: .item(PreviewFixtures.textItem("Step \($0)", seq: $0)), live: false)
        }
        var model = ParallelColumnModel(id: task.id, task: task, title: "Cell fixture", subtitle: "Codex",
                                        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
                                        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
                                        isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        model.onSubmitMessage = { _, _ in false }
        model.onCancelMessage = { _ in }
        let measured = ComposerFrameCapture()
        let content = measuringComposer(WorkflowActivityColumns(columns: [model], selectedTaskID: nil), taskID: task.id, capture: measured)
        let fixture = RedesignHost(content, size: CGSize(width: 380, height: 700))
        defer { fixture.close() }
        let host = fixture.host
        // when
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host)
.compactMap { $0 as? NSScrollView }
                .contains { $0.hasVerticalScroller && $0.contentView.bounds.height > 0 }
        }
        if count == 12 {
            await waitUntil {
                host.layoutSubtreeIfNeeded()
                return descendants(host)
.compactMap { $0 as? NSScrollView }
                    .first { $0.hasVerticalScroller }?
.documentView?
.bounds
.height ?? 0 > 400
            }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        let viewport = host.convert(scroll.contentView.bounds, from: scroll.contentView)
        let composer = try #require(fixture.element("parallel-column-composer"))
        #expect(fixture.string(composer, "accessibilityRole") == NSAccessibility.Role.group.rawValue)
        await waitUntil { measured.frame != nil }
        let composerFrame = try #require(measured.frame)
        let field = try #require(descendants(host)
.compactMap { $0 as? NSTextField }
            .first { $0.placeholderString == "Queue a message…" })
        let fieldFrame = host.convert(field.bounds, from: field)
        // then — activity fills exactly the region above the actual composer, which owns the bottom band.
        #expect(abs(viewport.maxY + HfRadius.Metrics.spacing10 - composerFrame.minY) < 2,
                "Activity must reach the composer with the production column's 10-point stack gap")
        #expect(abs(composerFrame.maxY - (host.bounds.maxY - HfRadius.Metrics.spacing16)) < 2,
                "The composer must fit inside the cell's bottom padding")
        #expect(composerFrame.contains(fieldFrame), "The native message field must remain inside its composer")
        #expect(viewport.height > 0 && composerFrame.height > fieldFrame.height)
        if count == 12 {
            #expect((scroll.documentView?.bounds.height ?? 0) > 400,
                    "Short older activity should fill the roomy cell without tapping Show all")
        }
    }

    @Test func givenSixTallRows_whenViewportResizes_thenLiveBottomFollowsButManualReadingStaysPut() async throws {
        // given — the recent suffix has the same six identities at every tested size.
        _ = NSApplication.shared
        let task = try #require(TaskInfo(.object([
            "task_id": .string("resize-fixture"), "backend": .string("codex"),
            "status": .string("completed"), "repo_path": .string("/tmp")
        ])))
        let text = Array(repeating: "A long activity line for wrapping and scrolling.", count: 30).joined(separator: "\n\n")
        let rows = (0 ..< 6).map {
            ConversationTimelineRow(id: "tall\($0)", taskID: task.id, timestamp: nil,
                                    kind: .item(PreviewFixtures.textItem(text, seq: $0)), live: false)
        }
        let model = ParallelColumnModel(id: task.id, task: task, title: "Resize fixture", subtitle: "Codex",
                                        isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil,
                                        rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
                                        isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        let host = NSHostingView(rootView: WorkflowActivityColumns(columns: [model], selectedTaskID: nil))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 380, height: 700),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return descendants(host)
.compactMap { $0 as? NSScrollView }
                .contains { $0.hasVerticalScroller && ($0.documentView?.bounds.height ?? 0) > 1000 && bottomDistance($0) <= 24 }
        }
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller })
        #expect(bottomDistance(scroll) <= 24)
        // when — shrinking changes only geometry, not activity or suffix IDs.
        window.setContentSize(CGSize(width: 380, height: 420))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            return scroll.contentView.bounds.height < 400 && bottomDistance(scroll) <= 24
        }
        // then
        #expect(bottomDistance(scroll) <= 24, "Resizing while following keeps the latest activity visible")
        // when — manual history reading must remain suspended through another resize.
        let document = try #require(scroll.documentView)
        let top = document.isFlipped ? document.bounds.minY : document.bounds.maxY - scroll.contentView.bounds.height
        scroll.contentView.scroll(to: CGPoint(x: 0, y: top))
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            return bottomDistance(scroll) > 1000
        }
        window.setContentSize(CGSize(width: 380, height: 600))
        await waitUntil {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            return scroll.contentView.bounds.height > 400
        }
        // then
        #expect(bottomDistance(scroll) > 1000, "Resize must not jump manual reading back to live")
    }

    private func measuringComposer(_ content: some View, taskID: String, capture: ComposerFrameCapture) -> some View {
        content.overlayPreferenceValue(ParallelComposerBounds.self) { anchors in
            GeometryReader { geometry in
                Color.clear.onGeometryChange(for: CGRect?.self) { _ in
                    anchors[taskID].map { geometry[$0] }
                } action: { capture.frame = $0 }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func bottomDistance(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .infinity }
        let visible = scroll.documentVisibleRect
        return document.isFlipped ? document.bounds.maxY - visible.maxY : visible.minY - document.bounds.minY
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}

@MainActor private final class ComposerFrameCapture {
    var frame: CGRect?
}
