import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

/// Reproduces issue #11 with a normalized event-log fixture. Each event contains the complete
/// assistant text seen at that point in the stream, as produced by the monitor's folded timeline.
/// The fixture deliberately splits Markdown markers at awkward boundaries.
@MainActor @Suite(.serialized) struct ActivityFeedStreamingIssue11HostedTests {
    @Test func givenAwkwardMarkdownDeltas_whenAssistantTextStreams_thenPreparedBlocksAndFinalGeometryRemainStable() async throws {
        _ = NSApplication.shared
        let fixture = ActivityFeedStreamingIssue11Fixture()
        let state = ParallelColumnUIState()
        let host = NSHostingView(rootView: AnyView(fixture.feed(text: fixture.snapshots[0], state: state)))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        let output = URL(fileURLWithPath: "/tmp/harflow-issue11", isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var documentHeights: [CGFloat] = []
        var blockKinds: [[String]] = []
        var previous: [String: StreamingMarkdownState] = [:]
        var priorNativeRevision = -1

        for (index, text) in fixture.snapshots.enumerated() {
            let beforeRevision = index == 0 ? -1 : nativeRevision(in: host, fallback: priorNativeRevision)
            if index > 0 {
                host.rootView = AnyView(fixture.feed(text: text, state: state, previous: previous))
            }
            priorNativeRevision = try await requireCommittedUpdate(host: host, state: state, afterRevision: beforeRevision)
            let snapshotScroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
            #expect(state.followLive.isFollowing)
            #expect(abs(snapshotScroll.documentVisibleRect.maxY - (snapshotScroll.documentView?.bounds.maxY ?? 0)) <= 3)
            let prepared = ActivityRowsBuilder.markdownSnapshot(
                from: [ActivityFixture.text(1, text, task: "issue-11", streaming: true)], previous: previous
            )
            if let markdown = prepared["issue-11#1"] {
                blockKinds.append(markdown.blocks.map(fixture.kindName))
                previous = prepared
            }
            documentHeights.append(documentHeight(in: host))
            priorNativeRevision = nativeRevision(in: host, fallback: priorNativeRevision)
            try captureIfEnabled(host: host, output: output, index: index)
        }

        print("issue-11 fixture snapshots=\(fixture.snapshots.count) documentHeights=\(documentHeights) blockKinds=\(blockKinds)")
        #expect(documentHeights.contains { $0 > 450 }, "The streamed activity must overflow the narrow viewport")
        #expect(blockKinds.contains { $0.contains("code") } && blockKinds.contains { $0.contains("table") })

        let finalText = fixture.snapshots.last!
        let finalRow = ActivityFixture.text(1, finalText, task: "issue-11", streaming: false)
        let finalState = ActivityRowsBuilder.markdownSnapshot(from: [finalRow], previous: previous)
        let replay = ActivityRowsBuilder.markdownSnapshot(from: [finalRow], previous: finalState)
        #expect(replay == finalState)
        #expect(finalState[finalRow.id]?.blocks == previous[finalRow.id]?.blocks)

        let streamingHeight = documentHeights.last ?? 0
        let finalizedHeight = try await finalizedHeight(host: host, fixture: fixture,
            state: state, previous: previous, afterRevision: priorNativeRevision)
        #expect(streamingHeight > 450)
        #expect(finalizedHeight > 450)
        #expect(abs(finalizedHeight - streamingHeight) <= 1)
    }

    @Test func givenPausedPreparedTextRow_whenSameIDTextGrows_thenAnchorSurvivesFinalization() async throws {
        _ = NSApplication.shared
        let fixture = ActivityFeedStreamingIssue11Fixture()
        let state = ParallelColumnUIState()
        let initial = fixture.snapshots.last! + String(repeating: "\n\nStable reading paragraph.", count: 40)
        let host = NSHostingView(rootView: AnyView(fixture.feed(text: initial, state: state)))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        let initialRevision = try await requireCommittedUpdate(host: host, state: state, afterRevision: -1)
        let scroll = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first)
        let bottom = max(0, (scroll.documentView?.bounds.height ?? 0) - scroll.contentView.bounds.height)
        try #require(bottom > 200)
        activityNativeTestScroll(scroll, to: max(0, bottom - 80))
        await waitUntil { !state.followLive.isFollowing && state.anchor != nil }
        try #require(!state.followLive.isFollowing)
        let before = try #require(state.anchor)
        let beforeOffset = scroll.documentVisibleRect.minY
        let beforeHeight = documentHeight(in: host)
        let grown = initial + "\n\n" + String(repeating: "Additional streamed paragraph.\n\n", count: 20)
        let row = ActivityFixture.text(1, grown, task: "issue-11", streaming: true)
        let prepared = ActivityRowsBuilder.markdownSnapshot(from: [row], previous: [:])
        let grownRevision = nativeRevision(in: host, fallback: initialRevision)
        host.rootView = AnyView(fixture.feed(text: grown, state: state, previous: prepared))
        _ = try await requireCommittedUpdate(host: host, state: state, afterRevision: grownRevision)
        #expect(documentHeight(in: host) > beforeHeight)
        #expect(abs(scroll.documentVisibleRect.minY - beforeOffset) < 4)
        #expect(state.anchor?.id == before.id)
        let finalRow = ActivityFixture.text(1, grown, task: "issue-11", streaming: false)
        let final = ActivityRowsBuilder.markdownSnapshot(from: [finalRow], previous: prepared)
        let finalRevision = nativeRevision(in: host, fallback: grownRevision)
        host.rootView = AnyView(fixture.feed(text: grown, state: state, previous: final, streaming: false))
        _ = try await requireCommittedUpdate(host: host, state: state, afterRevision: finalRevision)
        #expect(!state.followLive.isFollowing)
        #expect(state.anchor?.id == before.id)
        #expect(abs((state.anchor?.relativeOffset ?? .infinity) - before.relativeOffset) < 4)
    }

    // MARK: - Nested list geometry

    private static let nestedListText = "- x\n  - x\n    - x"

    @Test func givenNestedBulletsInEachFeedStyle_whenRendered_thenTextOriginsStepByTheListIndent() async throws {
        _ = NSApplication.shared
        let prepared = StreamingMarkdownState().updating(text: Self.nestedListText, isStreaming: false)
        for style in [ActivityFeedStyle.standard, .transcript] {
            // given
            let view = ReadingMarkdownView(text: Self.nestedListText, prepared: prepared)
                .environment(\.activityFeedStyle, style)

            // when
            let origins = try renderedTextOrigins(of: view)

            // then
            #expect(origins.count == 3, "\(style) rendered \(origins)")
            guard origins.count == 3 else { continue }
            let indent = TaskScreenStyle.AgentProse.listIndent
            #expect(abs((origins[1] - origins[0]) - indent) <= 1, "\(style) depth 1 origin \(origins)")
            #expect(abs((origins[2] - origins[0]) - 2 * indent) <= 1, "\(style) depth 2 origin \(origins)")
        }
    }

    @Test func givenNestedBulletsInMarkdownText_whenRendered_thenTextOriginsStepByTheLevelIndentToken() async throws {
        _ = NSApplication.shared
        // given
        let view = MarkdownText(text: Self.nestedListText)

        // when
        let origins = try renderedTextOrigins(of: view)

        // then
        #expect(origins.count == 3, "rendered \(origins)")
        guard origins.count == 3 else { return }
        let indent = HfRadius.Metrics.markdownListLevelIndent
        #expect(abs((origins[1] - origins[0]) - indent) <= 1, "depth 1 origin \(origins)")
        #expect(abs((origins[2] - origins[0]) - 2 * indent) <= 1, "depth 2 origin \(origins)")
    }

    @Test func givenTheTranscriptListIndent_whenComparedWithTheLevelToken_thenTheyAreEqual() {
        // given / when / then
        #expect(TaskScreenStyle.AgentProse.listIndent == HfRadius.Metrics.markdownListLevelIndent)
    }

    @Test func givenNestedListDeltas_whenAssistantTextStreams_thenDepthsStayStableAndFinalHeightMatches() async throws {
        _ = NSApplication.shared
        // given
        let fixture = ActivityFeedStreamingIssue11Fixture()
        let state = ParallelColumnUIState()
        let deltas = ["Intro.\n\n1. First item\n", " ", " - nested", " bullet one\n    ", "- deeper bullet\n  - nested bullet two\n"]
        let host = NSHostingView(rootView: AnyView(fixture.feed(text: deltas[0], state: state)))
        let window = activityMountedTestWindow(host, style: [.titled, .resizable])
        defer { window.contentView = nil; window.close() }
        window.orderFront(nil)
        var previous: [String: StreamingMarkdownState] = [:]
        var revision = -1
        var text = ""
        var seen: [Int: Int] = [:]

        // when
        for (index, delta) in deltas.enumerated() {
            text += delta
            let beforeRevision = revision
            if index > 0 { host.rootView = AnyView(fixture.feed(text: text, state: state, previous: previous)) }
            revision = try await requireCommittedUpdate(host: host, state: state, afterRevision: beforeRevision)
            previous = ActivityRowsBuilder.markdownSnapshot(
                from: [ActivityFixture.text(1, text, task: "issue-11", streaming: true)], previous: previous
            )
            for block in previous["issue-11#1"]?.blocks ?? [] {
                guard case .bullet(_, let depth) = block.content else { continue }
                if let earlier = seen[block.id] { #expect(earlier == depth) }
                seen[block.id] = depth
            }
        }
        let streamingHeight = documentHeight(in: host)
        host.rootView = AnyView(fixture.feed(text: text, state: state, previous: previous, streaming: false))
        _ = try await requireCommittedUpdate(host: host, state: state, afterRevision: nativeRevision(in: host, fallback: revision))
        let finalised = documentHeight(in: host)

        // then
        #expect(seen.values.sorted() == [1, 1, 2])
        #expect(abs(finalised - streamingHeight) <= 1)
    }

    /// The x origin (points) of the last ink cluster of each text line in the rendered view: the item
    /// text, to the right of its bullet glyph.
    private func renderedTextOrigins(of content: some View) throws -> [CGFloat] {
        let size = CGSize(width: 400, height: 200)
        let host = NSHostingView(rootView: AnyView(
            content.padding(0)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        ))
        let window = activityMountedTestWindow(host, style: [.titled])
        defer { window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.orderFront(nil)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        var origins: [CGFloat] = []
        var bandColumns: [Int] = []
        func closeBand() {
            defer { bandColumns = [] }
            guard !bandColumns.isEmpty else { return }
            let sorted = bandColumns.sorted()
            var clusterStart = sorted[0]
            var last = sorted[0]
            for column in sorted.dropFirst() {
                if CGFloat(column - last) > 4 * scale { clusterStart = column }
                last = column
            }
            origins.append(CGFloat(clusterStart) / scale)
        }
        for y in 0 ..< bitmap.pixelsHigh {
            var columns: [Int] = []
            for x in 0 ..< bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent + color.greenComponent + color.blueComponent < 2.4 { columns.append(x) }
            }
            if columns.isEmpty { closeBand() } else { bandColumns.append(contentsOf: columns) }
        }
        closeBand()
        return origins
    }

    private func finalizedHeight(host: NSHostingView<AnyView>, fixture: ActivityFeedStreamingIssue11Fixture,
                                 state: ParallelColumnUIState,
                                 previous: [String: StreamingMarkdownState], afterRevision: Int) async throws -> CGFloat {
        let beforeRevision = nativeRevision(in: host, fallback: afterRevision)
        host.rootView = AnyView(fixture.feed(text: fixture.snapshots.last!, state: state,
            previous: previous, streaming: false))
        _ = try await requireCommittedUpdate(host: host, state: state, afterRevision: beforeRevision)
        return descendants(host)
.compactMap { $0 as? NSScrollView }
            .first(where: { $0.hasVerticalScroller })?
.documentView?
.bounds
.height ?? 0
    }

    private func requireCommittedUpdate(host: NSView, state: ParallelColumnUIState,
                                        afterRevision: Int) async throws -> Int {
        var revision = -1
        await waitUntil(timeout: 3) {
            host.layoutSubtreeIfNeeded()
            revision = nativeRevision(in: host, fallback: -1)
            return state.viewportPositioned && revision > afterRevision
        }
        try #require(revision > afterRevision, "native row did not commit a newer snapshot")
        return revision
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func documentHeight(in host: NSView) -> CGFloat {
        descendants(host)
.compactMap { $0 as? NSScrollView }
            .first(where: { $0.hasVerticalScroller })?
.documentView?
.bounds
.height ?? 0
    }

    private func nativeRevision(in host: NSView, fallback: Int) -> Int {
        descendants(host)
.compactMap { $0 as? ActivityFeedNativeCell }
            .first(where: { $0.entryID == "issue-11#1" && $0.isCoherentNativeMeasurement })?
.nativeSnapshotRevision ?? fallback
    }

    private func captureIfEnabled(host: NSView, output: URL, index: Int) throws {
        guard ProcessInfo.processInfo.environment["HARFLOW_ISSUE11_CAPTURE"] == "1" else { return }
        try capture(host: host, to: output.appendingPathComponent(String(format: "frame-%02d.png", index)))
    }

    private func capture(host: NSView, to url: URL) throws {
        guard host.bounds.width > 0, host.bounds.height > 0 else { return }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        host.window?.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return }
        try data.write(to: url, options: .atomic)
    }
}

@MainActor private struct ActivityFeedStreamingIssue11Fixture {
    let snapshots: [String]

    init() {
        let long = "\n\nThis paragraph is deliberately long enough to overflow the narrow reading viewport. "
            + String(repeating: "Earlier lines stay visible while the tail grows. ", count: 12)
        let final = "The answer starts with a **streaming response." + long
            + "\n\n- first item\n- second item\n\n```swift\nlet value = true\n```\n\n"
            + "| Name | Value |\n|---|---|\n| status | complete |\n\nThe final paragraph keeps growing."
        let head = "The answer starts with a **streaming response."
        let partialHead = "The answer starts with a **streaming"
        let codePrefix = head + long + "\n\n- first item\n- second item\n\n```swift\nlet value = "
        self.snapshots = [
            partialHead,
            head,
            head + long,
            codePrefix,
            codePrefix + "true\n```\n\n| Name | Value |",
            final
        ]
    }

    func feed(text: String, state: ParallelColumnUIState,
              previous: [String: StreamingMarkdownState] = [:], streaming: Bool = true) -> some View {
        let row = ActivityFixture.text(1, text, task: "issue-11", streaming: streaming)
        return ActivityFeedView(rows: ActivityRowsBuilder.build(from: [row], markdown: previous), start: nil,
                                history: EventHistoryState(), isLoading: false, state: state,
                                onLoadMore: nil).frame(width: 420, height: 450)
    }

    func kindName(_ block: StreamingMarkdownBlock) -> String {
        switch block.content {
        case .heading: "heading"
        case .bullet: "bullet"
        case .code: "code"
        case .paragraph: "paragraph"
        case .table: "table"
        case .numbered: "numbered"
        case .quote: "quote"
        case .rule: "rule"
        }
    }
}
