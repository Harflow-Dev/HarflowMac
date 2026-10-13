import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

/// Synthetic regression for the narrow Activity mount where the newest assistant row is taller
/// than the viewport. It intentionally uses no private task data and no forced layout call.
@MainActor @Suite(.serialized) struct ActivityFeedLongMarkdownHostedTests {
    @Test func givenEightTallActivityRows_whenTaskDetailMounts_thenBottomAndVisibleGeometryRemainStable() async throws {
        // given — a narrow first mount with a tall latest assistant response and mixed rows.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let longText = String(
            repeating: "A long assistant response wraps in the narrow reading column and includes "
                + "**details**, `tokens`, and changing line lengths. ", count: 10
        )
        let items = tallActivityItems(longText: longText)
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = items
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        let recorder = FirstMountRecorder(controller: controller)
        // when — mount through the normal run loop and wait for the native table to settle.
        window.orderFront(nil)
        defer {
            print("synthetic-first-mount diagnostics dropped=\(recorder.droppedDiagnosticCount) trace=\(recorder.diagnosticTrace.joined(separator: " | "))")
            recorder.detach(from: controller)
            harness.sut.didDisappear(); window.contentViewController = nil; window.close()
        }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count >= 5 }
        await waitUntil(timeout: 5) { activityScroll(in: controller.view)?.documentView is NSTableView }

        let scroll = try #require(activityScroll(in: controller.view))
        let document = try #require(scroll.documentView)
        let table = try #require(document as? NSTableView)
        scroll.contentView.postsBoundsChangedNotifications = true
        await waitForMaterializedSample(recorder, controller: controller, table: table, scroll: scroll)
        try #require(!recorder.validSamples.isEmpty,
                     "The first valid bottom sample must include materialized overflow rows")
        // Keep a bounded observation window: after the first settle, the test measures whether
        // any residual first-mount motion reverses direction or repeatedly changes height.
        try await Task.sleep(for: .milliseconds(500))
        // Capture a terminal sample even when the settled table emits no further bounds change.
        recorder.captureCurrent(controller: controller)
        // then — the feed reaches bottom with visible rows and no oscillating geometry.
        let metrics = firstMountMetrics(samples: recorder.validSamples)
        let trace = recorder.mountTrace.map(\.logLine).joined(separator: " | ")
        try #require(recorder.validSamples.count >= 2,
                     "The bounded observation must compare an initial and terminal valid sample")
        print(
            "synthetic-first-mount rows=\(table.numberOfRows) notifications=\(recorder.boundsNotificationCount) "
                + "reversals=\(metrics.reversals) heightTransitions=\(metrics.heightTransitions) "
                + "validSamples=\(recorder.validSamples.count) stableIDs=\(metrics.stableIDs) "
                + "stableGeometry=\(metrics.stableGeometry) trace=\(trace)"
        )
        #expect(table.numberOfRows >= 5)
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        #expect(document.bounds.maxY - scroll.documentVisibleRect.maxY <= 3)
        #expect(recorder.boundsNotificationCount > 0, "The mounted table must publish bounds notifications")
        #expect(!metrics.comparisonFrames.isEmpty,
                "The stability comparison must include an oversized or fully visible row")
        #expect(metrics.reversals == 0)
        #expect(metrics.heightTransitions < 3)
        #expect(metrics.stableIDs, "The valid bottom samples must retain the same realized row identities")
        #expect(metrics.stableGeometry, "The valid bottom samples must retain viewport-relative row geometry")
    }

    private func waitForMaterializedSample(_ recorder: FirstMountRecorder, controller: NSViewController,
                                           table: NSTableView, scroll: NSScrollView) async {
        await waitUntil(timeout: 5) {
            // Bounds can settle before native cells realize; observe without causing layout.
            recorder.captureCurrent(controller: controller)
            return !recorder.validSamples.isEmpty && table.numberOfRows >= 5
                && table.bounds.height > scroll.contentView.bounds.height
        }
    }

    @Test func givenTwoLatestRowsAndTallMarkdown_whenTaskDetailOpensNarrow_thenVisibleRowsAreMeasured() async throws {
        // given
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let text = markdownBody()
        let prompt = try #require(TaskEvent(line: #"{"v":1,"seq":0,"kind":"user_message","text":"Review this change","source":"initial"}"#))
        let assistantLine = #"{"v":1,"seq":1,"kind":"assistant_text","text":""# + text.replacingOccurrences(of: "\n", with: "\\n") + #""}"#
        let assistant = try #require(TaskEvent(line: assistantLine))
        let events = [prompt, assistant]
        harness.detailBox.value = helper.task(status: "completed")
        harness.eventsBox.value = events
        harness.itemsOverride.value = Timeline.items(from: events)
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        // when — settle through the normal window run loop; never call layoutSubtreeIfNeeded.
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == 2 }
        await waitUntil(timeout: 5) {
            guard let scroll = descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }),
                  let document = scroll.documentView else { return false }
            let visible = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
                .map { $0.convert($0.bounds, to: document) }
                .filter { $0.intersects(scroll.documentVisibleRect) }
            return visible.count >= 1 && document.bounds.height > scroll.contentView.bounds.height
        }

        // then
        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
        #expect(document.bounds.height > scroll.contentView.bounds.height)
        #expect(!visible.isEmpty, "The initial narrow viewport must realize at least one Activity row")
    }

    @Test func givenTallAssistantThenSmallFinishedRow_whenTaskDetailOpensNarrow_thenBothInitialRowsAreMeasured() async throws {
        // given — this ordering matches the incident: the long assistant item is followed by
        // the small completion marker.  The completion row must not be allowed to stand in for
        // the preceding row while the lazy stack is still estimating its height.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = [
            PreviewFixtures.textItem(markdownBody(), seq: 1),
            PreviewFixtures.finishedItem(seq: 2)
        ]
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        // Settle only through the normal run loop.  In particular, do not force a SwiftUI layout
        // pass before taking the baseline measurement.
        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == 2 }
        await waitUntil(timeout: 5) {
            guard let scroll = descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }),
                  let document = scroll.documentView else { return false }
            let measured = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
                .map { $0.convert($0.bounds, to: document) }
            let visible = measured.filter { $0.intersects(scroll.documentVisibleRect) }
            return measured.count >= 2 && visible.count >= 2
        }

        let scroll = try #require(descendants(controller.view).compactMap({ $0 as? NSScrollView }).first(where: { $0.hasVerticalScroller }))
        let document = try #require(scroll.documentView)
        let visible = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
        let allMeasured = descendants(document)
.compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
        print("FDC synthetic long-then-finished: document=\(document.bounds), "
            + "visible=\(scroll.documentVisibleRect), measured=\(allMeasured)")
        #expect(visible.count >= 2, "Both the tall assistant row and following finished row must be measured in the initial viewport")
        #expect(allMeasured.contains { $0.height >= scroll.documentVisibleRect.height * 3 },
                "The complete known long markdown must occupy at least three viewports; a one-point native slot is not text evidence")
    }

    @Test func givenLatestTallRows_whenOlderHistoryIsPublished_thenLatestRowsRemainAtBottom() async throws {
        // This models the delivery order used by the real task: the newest folded page mounts
        // first, then the older pages are prepended into the same timeline while the feed is
        // already following the live end.
        _ = NSApplication.shared
        let helper = TaskDetailVMTests()
        let harness = helper.makeSUT()
        let latest = [
            PreviewFixtures.textItem(markdownBody(), seq: 1),
            PreviewFixtures.finishedItem(seq: 2)
        ]
        let older = groupedOlderHistory()
        harness.detailBox.value = helper.task(status: "completed")
        harness.itemsOverride.value = latest
        harness.eventsAvailabilityBox.value = .available
        let controller = NSHostingController(rootView: NavigationStack { TaskDetailView(harness.sut) }.withPresentationContext())
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { harness.sut.didDisappear(); window.contentViewController = nil; window.close() }
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])

        await waitUntil(timeout: 5) { harness.sut.timelineWorker == nil && harness.sut.timelineModel.rows.count == latest.count }
        await waitUntil(timeout: 5) { atBottom(in: controller.view) && visibleMeasurementCount(in: controller.view) >= 2 }

        // when — older content is delivered after the newest page has settled.
        harness.itemsOverride.value = older + latest
        harness.itemsSubject.send(older + latest)
        await waitUntil(timeout: 5) {
            harness.sut.timelineWorker == nil
                && harness.sut.timelineModel.rows.count == older.count + latest.count
        }
        await waitUntil(timeout: 5) {
            atBottom(in: controller.view) && visibleMeasurementCount(in: controller.view) >= 2
        }

        // then — publishing history must preserve the live end, including both rows that were
        // visible before the prepend. A List implementation that loses its native scroll identity
        // or restores against an estimated document height fails this check by landing at the top.
        #expect(atBottom(in: controller.view), "Publishing older history must preserve the live bottom")
        #expect(visibleMeasurementCount(in: controller.view) >= 2,
                "The tall latest assistant and following Finished row must remain realized")
    }

    private func markdownBody() -> String {
        var sections = [
            "# Review notes", "## Findings", "- The first finding keeps the row tall.",
            "- The second finding contains `inline code`."
        ]
        sections += ["```swift\nlet sample = true\n```", "### Details"]
        sections += (0 ..< 12).map { index in
            "Paragraph \(index): This synthetic assistant response wraps across the narrow Activity reading column "
                + "and remains taller than the initial viewport. It includes **emphasis**, `tokens`, and enough "
                + "prose to exercise markdown layout."
        }
        return sections.joined(separator: "\n\n")
    }

    private func tallActivityItems(longText: String) -> [TimelineItem] {
        [
            PreviewFixtures.textItem(longText, seq: 1),
            PreviewFixtures.toolItem(tool: "Read", category: "read",
                                     path: "/fictional/Sources/Activity.swift", seq: 2,
                                     callID: "fixture-read-1"),
            PreviewFixtures.toolItem(tool: "Read", category: "read",
                                     path: "/fictional/Tests/Activity.swift", seq: 3,
                                     callID: "fixture-read-2"),
            PreviewFixtures.textItem(longText, seq: 4),
            PreviewFixtures.toolItem(tool: "Bash", category: "shell",
                                     command: "swift test --filter Activity", seq: 5,
                                     callID: "fixture-shell-1"),
            PreviewFixtures.toolItem(tool: "Bash", category: "shell",
                                     command: "swift test --filter ActivityPending", seq: 6,
                                     callID: "fixture-shell-2"),
            PreviewFixtures.finishedItem(seq: 7),
            PreviewFixtures.textItem(longText, seq: 8)
        ]
    }

    private func firstMountMetrics(samples: [FirstMountSample]) -> (
        reversals: Int, heightTransitions: Int, comparisonFrames: [[CGRect]], stableIDs: Bool,
        stableGeometry: Bool
    ) {
        let offsets = samples.map(\.offset)
        let heights = samples.map(\.documentHeight)
        let directions = zip(offsets, offsets.dropFirst()).compactMap { pair -> Int? in
            let movement = pair.1 - pair.0
            guard abs(movement) > 5 else { return nil }
            return movement > 0 ? 1 : -1
        }
        let first = samples.first
        let stableIDs = samples.dropFirst().allSatisfy { sample in
            guard let first else { return false }
            return !first.comparisonRowIDs.isEmpty
                && first.comparisonRowIDs.allSatisfy(sample.comparisonRowIDs.contains)
        }
        let stableGeometry = samples.dropFirst().allSatisfy { sample in
            guard let first else { return false }
            let firstByID = Dictionary(uniqueKeysWithValues: zip(first.comparisonRowIDs, first.comparisonFrames))
            let sampleByID = Dictionary(uniqueKeysWithValues: zip(sample.comparisonRowIDs, sample.comparisonFrames))
            return firstByID.allSatisfy { id, frame in
                guard let current = sampleByID[id] else { return false }
                return abs((frame.minY - first.offset) - (current.minY - sample.offset)) < 3
            }
        }
        return (
            zip(directions, directions.dropFirst()).filter { $0 != $1 }.count,
            zip(heights, heights.dropFirst()).filter { abs($1 - $0) > 1 }.count,
            samples.map(\.comparisonFrames).filter { !$0.isEmpty },
            stableIDs,
            stableGeometry
        )
    }

    private final class FirstMountRecorder: @unchecked Sendable {
        var mountTrace: [FirstMountSample] = []
        var validSamples: [FirstMountSample] = []
        private(set) var boundsNotificationCount = 0
        private(set) var diagnosticTrace: [String] = []
        private var observer: NSObjectProtocol?
        private var diagnosticViewIDs: Set<ObjectIdentifier> = []
        private var diagnosticAttachments: [DiagnosticAttachment] = []
        private var diagnosticSequence = 0
        private(set) var droppedDiagnosticCount = 0

        @MainActor init(controller: NSViewController) {
            self.observer = nil
            attachDiagnostics(in: controller)
            self.observer = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification, object: nil, queue: .main
            ) { [weak self, weak controller] notification in
                guard let self, let controller else { return }
                guard let object = notification.object as? NSView else { return }
                let objectID = ObjectIdentifier(object)
                MainActor.assumeIsolated {
                    self.record(objectID: objectID, in: controller, fromBoundsNotification: true)
                }
            }
        }

        deinit {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }

        @MainActor func detach(from controller: NSViewController) {
            for attachment in diagnosticAttachments {
                attachment.view?.restorationDiagnostic = attachment.original
            }
            diagnosticAttachments.removeAll()
            diagnosticViewIDs.removeAll()
        }

        @MainActor private func record(objectID: ObjectIdentifier, in controller: NSViewController, fromBoundsNotification: Bool = false) {
            attachDiagnostics(in: controller)
            guard let scroll = Self.activityScroll(in: controller.view), let document = scroll.documentView,
                  document is NSTableView, ObjectIdentifier(scroll.contentView) == objectID else { return }
            if fromBoundsNotification { boundsNotificationCount += 1 }
            let visible = Self.descendants(document)
                .compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
                .compactMap { view -> (ObjectIdentifier, CGRect)? in
                    let frame = view.convert(view.bounds, to: document)
                    return frame.intersects(scroll.documentVisibleRect)
                        ? (ObjectIdentifier(view), frame) : nil
                }
            let fullyVisible = visible.filter { $0.1.minY >= scroll.documentVisibleRect.minY
                && $0.1.maxY <= scroll.documentVisibleRect.maxY
            }
            let midpoint = scroll.documentVisibleRect.midY
            let comparison: [(ObjectIdentifier, CGRect)] = if !fullyVisible.isEmpty {
                fullyVisible
            } else if let midpointRow = visible.first(where: {
                $0.1.contains(CGPoint(x: $0.1.midX, y: midpoint))
            }) {
                [midpointRow]
            } else {
                visible.max { lhs, rhs in
                    lhs.1.intersection(scroll.documentVisibleRect).height
                        < rhs.1.intersection(scroll.documentVisibleRect).height
                }
.map { [$0] } ?? []
            }
            let sample = FirstMountSample(
                timestamp: ProcessInfo.processInfo.systemUptime,
                offset: scroll.documentVisibleRect.minY,
                documentHeight: document.bounds.height,
                viewportHeight: scroll.contentView.bounds.height,
                insets: scroll.contentInsets,
                rowIDs: visible.map(\.0),
                rowFrames: visible.map(\.1),
                comparisonRowIDs: comparison.map(\.0),
                comparisonFrames: comparison.map(\.1)
            )
            mountTrace.append(sample)
            appendDiagnostic(String(format: "sample t=%.3f style=%ld auto=%d outer=%.1f clip=(%.1f,%.1f) offset=%.1f doc=%.1f rows=%d providers=%d active=%@",
                                    sample.timestamp, scroll.scrollerStyle.rawValue, scroll.autohidesScrollers ? 1 : 0,
                                    scroll.frame.width, scroll.contentView.bounds.width, scroll.contentView.bounds.height,
                                    sample.offset, sample.documentHeight, sample.rowIDs.count,
                                    Self.observerViews(in: controller.view).count,
                                    Self.observerViews(in: controller.view)
.map { $0.anchorProvider?.isAnchorRestorationActive == true ? "1" : "0" }
                                        .joined(separator: ",")))
            let hasOverflow = sample.documentHeight > sample.viewportHeight
            let hasMaterializedRows = !sample.rowFrames.isEmpty
            let isBottom = sample.documentHeight - sample.offset - sample.viewportHeight <= 3
            if validSamples.isEmpty, ((document as? NSTableView)?.numberOfRows ?? 0) >= 5,
               hasOverflow, hasMaterializedRows, isBottom {
                validSamples.append(sample)
            } else if !validSamples.isEmpty {
                validSamples.append(sample)
            }
        }

        @MainActor func captureCurrent(controller: NSViewController) {
            attachDiagnostics(in: controller)
            guard let scroll = Self.activityScroll(in: controller.view) else { return }
            record(objectID: ObjectIdentifier(scroll.contentView), in: controller)
        }

        @MainActor private func attachDiagnostics(in controller: NSViewController) {
            if diagnosticTrace.isEmpty {
                let preferred = UserDefaults.standard.string(forKey: "AppleShowScrollBars") ?? "nil"
                let screen = NSScreen.main?.frame.debugDescription ?? "nil"
                appendDiagnostic("environment preferredStyle=\(NSScroller.preferredScrollerStyle.rawValue) AppleShowScrollBars=\(preferred) screen=\(screen)")
            }
            let views = Self.observerViews(in: controller.view)
            if views.isEmpty {
                appendDiagnostic("observer-sink missing t=\(ProcessInfo.processInfo.systemUptime)")
            }
            for view in views where diagnosticViewIDs.insert(ObjectIdentifier(view)).inserted {
                let attachment = DiagnosticAttachment(view: view, original: view.restorationDiagnostic)
                diagnosticAttachments.append(attachment)
                view.restorationDiagnostic = { [weak self] message in
                    self?.appendDiagnostic("observer \(message)")
                }
                appendDiagnostic("observer-sink attached t=\(ProcessInfo.processInfo.systemUptime)")
            }
        }

        private func appendDiagnostic(_ line: String) {
            if diagnosticTrace.count >= 300 {
                diagnosticTrace.remove(at: 100)
                droppedDiagnosticCount += 1
            }
            diagnosticSequence += 1
            diagnosticTrace.append(String(format: "#%03d t=%.6f %@",
                                           diagnosticSequence, ProcessInfo.processInfo.systemUptime, line))
        }

        private final class DiagnosticAttachment {
            weak var view: ParallelScrollObservationView?
            let original: ((String) -> Void)?

            init(view: ParallelScrollObservationView, original: ((String) -> Void)?) {
                self.view = view
                self.original = original
            }
        }

        @MainActor private static func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }

        @MainActor private static func activityScroll(in view: NSView) -> NSScrollView? {
            descendants(view).compactMap { $0 as? NSScrollView }.first(where: { $0.hasVerticalScroller })
        }

        @MainActor private static func observerViews(in view: NSView) -> [ParallelScrollObservationView] {
            descendants(view).compactMap { $0 as? ParallelScrollObservationView }
        }
    }

    private struct FirstMountSample {
        let timestamp: TimeInterval
        let offset: CGFloat
        let documentHeight: CGFloat
        let viewportHeight: CGFloat
        let insets: NSEdgeInsets
        let rowIDs: [ObjectIdentifier]
        let rowFrames: [CGRect]
        let comparisonRowIDs: [ObjectIdentifier]
        let comparisonFrames: [CGRect]

        var logLine: String {
            let frames = rowFrames.map { "(\($0.minX),\($0.minY),\($0.width),\($0.height))" }
                .joined(separator: ",")
            return String(
                format: "t=%.3f offset=%.1f doc=%.1f viewport=%.1f insets=(%.1f,%.1f,%.1f,%.1f) rows=%d frames=[%@]",
                timestamp, offset, documentHeight, viewportHeight, insets.top, insets.left,
                insets.bottom, insets.right, rowIDs.count, frames
            )
        }
    }

    /// The real failing snapshot contains folded runs of adjacent tool calls interspersed with
    /// prose. Keep the public regression on that same row shape so it exercises group identity and
    /// virtualization, rather than only a long flat list of text rows.
    private func groupedOlderHistory() -> [TimelineItem] {
        var items: [TimelineItem] = []
        for group in 0 ..< 5 {
            for member in 0 ..< 4 {
                let seq = group * 20 + member * 2 + 100
                items.append(PreviewFixtures.toolItem(
                    tool: "Read", category: "read", path: "/tmp/history-\(group)-\(member).swift",
                    seq: seq, callID: "history-read-\(group)-\(member)"
                ))
            }
            items.append(PreviewFixtures.textItem("Older history explanation \(group)", seq: group * 20 + 109))
            for member in 0 ..< 3 {
                let seq = group * 20 + member * 2 + 110
                items.append(PreviewFixtures.toolItem(
                    tool: "Bash", category: "shell", command: "swift test --filter History\(group)",
                    seq: seq, callID: "history-shell-\(group)-\(member)"
                ))
            }
            items.append(PreviewFixtures.textItem("Older history checkpoint \(group)", seq: group * 20 + 119))
        }
        return items
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func activityScroll(in view: NSView) -> NSScrollView? {
        descendants(view).compactMap { $0 as? NSScrollView }.first(where: { $0.hasVerticalScroller })
    }

    private func atBottom(in view: NSView) -> Bool {
        guard let scroll = activityScroll(in: view), let document = scroll.documentView else { return false }
        return abs(scroll.documentVisibleRect.maxY - document.bounds.maxY) <= 3
    }

    private func visibleMeasurementCount(in view: NSView) -> Int {
        guard let scroll = activityScroll(in: view), let document = scroll.documentView else { return 0 }
        return descendants(document)
            .compactMap { $0 as? ActivityFeedNativeCell }
.filter(\.isCoherentNativeMeasurement)
            .map { $0.convert($0.bounds, to: document) }
            .filter { $0.intersects(scroll.documentVisibleRect) }
            .count
    }

}
