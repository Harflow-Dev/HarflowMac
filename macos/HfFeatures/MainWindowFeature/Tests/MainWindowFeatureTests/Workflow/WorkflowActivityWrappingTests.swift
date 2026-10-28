import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowActivityWrappingTests

/// Both selected-task activity and the alternate native-subagent feed must reflow the actual
/// prepared text, rather than merely concealing an oversized document's horizontal scrollbar.
@MainActor @Suite(.serialized) struct WorkflowActivityWrappingTests {
    enum Sample: String, CaseIterable, Sendable {
        case json, unbroken, path, sha, inlineCode, fencedCode

        var displayed: String {
            switch self {
            case .json: "{\"payload\":\"" + String(repeating: "abcd", count: 80) + "END_JSON\"}"
            case .path: "/synthetic/" + String(repeating: "long_directory/", count: 24) + "END_PATH.swift"
            case .sha: String(repeating: "0123456789abcdef", count: 24) + "END_SHA"
            case .unbroken, .inlineCode, .fencedCode: String(repeating: "abcdefgh", count: 48) + "END_TOKEN"
            }
        }

        var source: String {
            switch self {
            case .inlineCode: "`" + displayed + "`"
            case .fencedCode: "```json\n" + displayed + "\n```"
            default: displayed
            }
        }
    }

    @Test(arguments: Sample.allCases)
    func givenPreparedTaskActivity_whenInspectorResizes_thenTextReflowsWithoutLosingItsSuffix(sample: Sample) async throws {
        // given — use the same prepared row and native table as TimelinePaneView.
        let item = PreviewFixtures.textItem(sample.source, seq: 1)
        let row = ConversationTimelineRow(id: "inspector-width", taskID: "synthetic", timestamp: nil,
                                          kind: .item(item), live: false)
        let prepared = StreamingMarkdownState().updating(text: sample.source, isStreaming: false)
        let state = ParallelColumnUIState()
        let feed = ActivityFeedView(rows: [.single(row, markdown: prepared)], start: nil,
                                   history: EventHistoryState(), isLoading: false,
                                   horizontalPadding: 24, state: state, onLoadMore: nil)
        try await exercise(AnyView(feed), sample: sample, usesNativeTable: true)
    }

    @Test(arguments: Sample.allCases)
    func givenPreparedNativeSubagentActivity_whenInspectorResizes_thenTextReflowsWithoutLosingItsSuffix(sample: Sample) async throws {
        // given — this production path bypasses ActivityFeedView and uses SwiftUI ScrollView.
        let item = PreviewFixtures.textItem(sample.source, seq: 1)
        let prepared = StreamingMarkdownState().updating(text: sample.source, isStreaming: false)
        let model = WorkflowNativeActivityModel(executionID: "synthetic", title: "Review", status: "completed",
                                                limited: false, items: [item], markdown: [item.id: prepared])
        try await exercise(AnyView(WorkflowNativeActivityView(model: model)), sample: sample, usesNativeTable: false)
    }

    private func exercise(_ content: AnyView, sample: Sample, usesNativeTable: Bool) async throws {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: content)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 500, height: 360),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        var heights: [CGFloat: CGFloat] = [:]

        // when — resize the same mounted feed; a fresh fixed-size rendering cannot prove reflow.
        for width: CGFloat in [500, 420, 320, 220, 500] {
            window.setContentSize(CGSize(width: width, height: 360))
            var lastHeight: CGFloat?
            var stableReports = 0
            await waitUntil(timeout: 5) {
                guard let scroll = self.scroll(in: host), let document = scroll.documentView,
                      abs(scroll.bounds.width - width) < 2,
                      activityNativeAccessibilityStrings(host).contains(where: { $0.contains(sample.displayed) }) else { return false }
                let height: CGFloat
                if usesNativeTable {
                    guard let table = document as? NSTableView,
                          let cell = descendants(host)
.compactMap({ $0 as? ActivityFeedNativeCell })
                            .first(where: \.isCoherentNativeMeasurement) else { return false }
                    height = table.rect(ofRow: table.row(for: cell)).height
                } else {
                    height = document.bounds.height
                }
                stableReports = height == lastHeight ? stableReports + 1 : 0
                lastHeight = height
                return stableReports >= 2
            }
            let scroll = try #require(self.scroll(in: host))
            let document = try #require(scroll.documentView)
            let height = try #require(lastHeight, "The rendered text must settle at width \(width)")
            try #require(stableReports >= 2, "The mounted content must reach coherent width-dependent geometry")
            if let previous = heights[width] {
                #expect(abs(previous - height) < 3, "Widening back must restore the original text height")
            }
            heights[width] = height

            // then — check glyph-bearing accessibility nodes as well as the enclosing document.
            #expect(!scroll.hasHorizontalScroller)
            #expect(document.bounds.width <= scroll.contentView.bounds.width + 1)
            #expect(activityNativeAccessibilityStrings(host).contains(where: { $0.contains(sample.displayed) }),
                    "The complete display string, including its suffix, must remain unchanged")
            let textElements = activityNativeAccessibilityTree(host).filter { object in
                guard let accessible = object as? any NSAccessibilityProtocol else { return false }
                return (accessible.accessibilityValue() as? String)?.contains(sample.displayed) == true
            }
            try #require(!textElements.isEmpty, "The actual text accessibility value must expose the full content")
            for element in textElements {
                let accessible = try #require(element as? any NSAccessibilityProtocol)
                let frame = scroll.contentView.convert(window.convertFromScreen(accessible.accessibilityFrame()), from: nil)
                #expect(frame.minX >= scroll.contentView.bounds.minX - 2)
                #expect(frame.maxX <= scroll.contentView.bounds.maxX + 2,
                        "The text itself must fit the inspector, not extend beyond a clipped document")
            }
        }
        let narrow = try #require(heights[220])
        let wide = try #require(heights[500])
        #expect(narrow > wide + 20, "Long text must gain vertical lines when the inspector narrows")
    }

    private func scroll(in view: NSView) -> NSScrollView? {
        descendants(view).compactMap { $0 as? NSScrollView }.first { $0.hasVerticalScroller }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }
}
