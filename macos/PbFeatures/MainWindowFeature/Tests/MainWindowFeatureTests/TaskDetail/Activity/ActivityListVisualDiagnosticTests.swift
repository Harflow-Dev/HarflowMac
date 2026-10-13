import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Native evidence for the ActivityFeedView before the activity list migration. The output is
/// opt-in and lives outside the repository so ordinary unit runs never publish screenshots.
@MainActor @Suite(.serialized) struct ActivityListVisualDiagnosticTests {
    @Test func givenActivityFeedFixture_whenHostedAtBaselineSizes_thenCaptureLightAndDark() async throws {
        guard let rawOutput = ProcessInfo.processInfo.environment["PB_ACTIVITY_BASELINE_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: rawOutput).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared

        for size in [CGSize(width: 420, height: 450), CGSize(width: 900, height: 600)] {
            for dark in [false, true] {
                for expanded in [false, true] {
                    let fixture = try await ActivityListBaselineFixture(size: size, dark: dark, expanded: expanded)
                    defer { fixture.close() }
                    let metrics = try await fixture.settle()
                    let bitmap = try fixture.captureBitmap()
                    try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    try #require(bitmapHasInk(bitmap), "(fixture.name): screenshot is blank")
                    try fixture.write(bitmap, metrics: metrics, output: output)
                    print("baseline=\(output.appendingPathComponent(fixture.name + ".png").path) metrics=\(metrics)")
                    if size == CGSize(width: 420, height: 450), !expanded {
                        let top = try await fixture.capturePausedTop()
                        try #require(bitmapHasInk(top), "(fixture.name)-top: screenshot is blank")
                        try fixture.write(top, metrics: fixture.metrics() + " pausedTop=true", nameSuffix: "-top", output: output)
                        print("baseline=\(output.appendingPathComponent(fixture.name + "-top.png").path) pausedTop=true")
                    }
                }
            }
        }
    }

    @Test func givenParallelActivityFeedFixture_whenHostedAtBaselineSizes_thenCaptureLightAndDark() async throws {
        guard let rawOutput = ProcessInfo.processInfo.environment["PB_ACTIVITY_BASELINE_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: rawOutput).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared

        for size in [CGSize(width: 420, height: 450), CGSize(width: 900, height: 600)] {
            for dark in [false, true] {
                for expanded in [false, true] {
                    let fixture = try await ActivityListBaselineFixture(
                        size: size, dark: dark, expanded: expanded, surface: "parallel", horizontalPadding: 0
                    )
                    defer { fixture.close() }
                    let metrics = try await fixture.settle()
                    let bitmap = try fixture.captureBitmap()
                    try #require(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
                    try #require(bitmapHasInk(bitmap), "(\(fixture.name)): screenshot is blank")
                    try fixture.write(bitmap, metrics: metrics, output: output)
                    print("parallel=\(output.appendingPathComponent(fixture.name + ".png").path) metrics=\(metrics)")
                }
            }
        }
    }

    @Test func givenPlainListWithTimelineRows_whenHosted_thenRecordNearestNativeScrollHierarchy() async throws {
        guard let rawOutput = ProcessInfo.processInfo.environment["PB_ACTIVITY_BASELINE_OUTPUT"] else { return }
        let output = URL(fileURLWithPath: rawOutput).standardizedFileURL
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let reportURL = output.appendingPathComponent("plain-list-hierarchy.txt")
        let probe = ListHierarchyProbe(reportURL: reportURL)
        let rows = ActivityListBaselineFixture.timelineRows
        let root = List {
            ForEach(rows) { row in
                if case .item(let item) = row.kind {
                    if row.id == rows.first?.id {
                        TimelineRow(model: TimelineRowModel(item: item, start: rows.first?.timestamp, live: row.live))
                            .background(probe)
                            .listRowSeparator(.hidden)
                    } else {
                        TimelineRow(model: TimelineRowModel(item: item, start: rows.first?.timestamp, live: row.live))
                            .listRowSeparator(.hidden)
                    }
                }
            }
        }
        .scrollChromeScope()
        .frame(width: 420, height: 450)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        await waitUntil(timeout: 5) {
            controller.view.layoutSubtreeIfNeeded()
            return probe.box.didObserve
        }
        try #require(probe.box.didObserve, "plain List hierarchy probe did not attach")
        print("list-hierarchy=\(reportURL.path)")
    }

    @Test func givenActivityFeedFixture_whenBlankRowAreaReceivesLocalClick_thenNativeListDoesNotSelectRow() async throws {
        guard ProcessInfo.processInfo.environment["PB_ACTIVITY_BASELINE_OUTPUT"] != nil else { return }
        let fixture = try await ActivityListBaselineFixture(
            size: CGSize(width: 420, height: 450), dark: false, expanded: false
        )
        defer { fixture.close() }
        _ = try await fixture.settle()
        let table = try #require(fixture.nativeTable)
        try #require(table.selectedRow == -1)
        let initialHighlight = table.selectionHighlightStyle
        let row = try #require(table.numberOfRows > 0 ? table.rect(ofRow: 0) : nil)
        // The trailing two points are outside the SwiftUI cell frame (the cell ends at x=411
        // in the 420-point fixture), so this exercises the List row hit area without invoking a
        // row control or relying on a programmatic selection.
        let localPoint = NSPoint(x: table.bounds.maxX - 2, y: row.midY)
        let windowPoint = table.convert(localPoint, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: windowPoint, modifierFlags: [], timestamp: 0,
                windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1
            ))
            fixture.window.sendEvent(event)
        }
        await Task.yield()
        #expect(table.selectedRow == -1)
        #expect(table.selectionHighlightStyle == initialHighlight)
    }
}

// MARK: - Baseline fixture

@MainActor private final class ActivityListBaselineFixture {
    let size: CGSize
    let dark: Bool
    let expanded: Bool
    let surface: String?
    let horizontalPadding: CGFloat
    let state: ParallelColumnUIState
    let controller: NSHostingController<AnyView>
    let window: NSWindow

    static var timelineRows: [ConversationTimelineRow] {
        [
            ActivityFixture.started(prompt: "Investigate the long activity reply and preserve the user's context.", task: "visual"),
            ActivityFixture.text(
                1,
                "### Findings\n\nThe activity feed keeps Markdown readable while tool work continues.\n\n"
                    + "- first finding\n- second finding",
                task: "visual"
            ),
            ActivityFixture.tool(2, task: "visual", category: "read", path: "/repo/Sources/Activity.swift", live: false),
            ActivityFixture.tool(3, task: "visual", category: "read", path: "/repo/Tests/ActivityTests.swift", live: false),
            ActivityFixture.separator("Follow-up turn", task: "visual"),
            ActivityFixture.text(4, "The completed read group is followed by a pending command.", task: "visual"),
            ActivityFixture.tool(5, task: "visual", category: "shell", command: "swift test --filter Activity", live: false),
            ActivityFixture.tool(6, task: "visual", category: "shell", command: "swift test --filter ActivityPending", resolved: false, live: true),
            ActivityFixture.row(7, task: "visual", live: false, .finished(status: "completed", exitCode: 0, summary: nil))
        ]
    }

    init(size: CGSize, dark: Bool, expanded: Bool, surface: String? = nil, horizontalPadding: CGFloat = 24) async throws {
        self.size = size; self.dark = dark; self.expanded = expanded
        self.surface = surface
        self.horizontalPadding = horizontalPadding
        self.state = ParallelColumnUIState()
        let timeline = Self.timelineRows
        let activityRows = ActivityRowsBuilder.build(from: timeline)
        if expanded {
            for row in activityRows {
                if case .toolGroup(let group) = row { state.expandedGroups.insert(group.id) }
            }
        }
        let feed = ActivityFeedView(rows: activityRows, start: timeline.first?.timestamp,
                                    history: EventHistoryState(hasMore: false), isLoading: false,
                                    tailValue: ActivityFeedTail(
                                        liveStep: LiveStep(rows: timeline, isRunning: true),
                                        pendingMessages: [PendingMessage(id: "pending", text: "Please also check the cold keychain path.")]),
                                    horizontalPadding: horizontalPadding, state: state, onLoadMore: nil,
                                    tailPresentation: .absent)
            .frame(width: size.width, height: size.height)
            .preferredColorScheme(dark ? .dark : .light)
        self.controller = NSHostingController(rootView: AnyView(feed))
        controller.sceneBridgingOptions = .all
        self.window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentViewController = controller
        window.orderFront(nil)
    }

    var name: String {
        let prefix = surface.map { "\($0)-" } ?? ""
        return "\(prefix)activity-list-\(Int(size.width))x\(Int(size.height))-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed")"
    }

    var nativeTable: NSTableView? {
        descendants(controller.view).compactMap { $0 as? NSTableView }.first
    }

    func settle() async throws -> String {
        var last = ""
        var stable = 0
        await waitUntil(timeout: 8) {
            controller.view.layoutSubtreeIfNeeded()
            let current = metrics()
            if current == last { stable += 1 } else { stable = 0; last = current }
            return stable >= 2 && current.contains("document=")
        }
        try #require(!last.isEmpty, "(name): layout never settled")
        return last
    }

    func metrics() -> String {
        let scroll = descendants(controller.view).compactMap { $0 as? NSScrollView }.first
        guard let scroll else { return "scroll=nil" }
        var result = "viewport=\(scroll.contentView.bounds.size) document=\(scroll.documentView?.frame.size ?? .zero) "
            + "scroller=\(scroll.hasVerticalScroller)/\(scroll.scrollerStyle.rawValue)/\(scroll.autohidesScrollers)"
        if let document = scroll.documentView {
            result += " nativeDocumentFrame=\(document.frame) nativeDocumentBounds=\(document.bounds) clipBounds=\(scroll.contentView.bounds)"
        }
        let tables = descendants(scroll).compactMap { $0 as? NSTableView }
        for (index, table) in tables.enumerated() {
            result += " table[\(index)]=style:\(table.style.rawValue),spacing:\(table.intercellSpacing),"
                + "selectionHighlight:\(table.selectionHighlightStyle.rawValue),selectedRow:\(table.selectedRow),"
                + "emptySelection:\(table.allowsEmptySelection),multipleSelection:\(table.allowsMultipleSelection),"
                + "frame:\(table.frame),bounds:\(table.bounds),rows:\(table.numberOfRows),"
                + "columns:\(table.numberOfColumns),column0:\(table.numberOfColumns > 0 ? table.rect(ofColumn: 0) : .zero)"
            if table.numberOfRows > 0, table.numberOfColumns > 0 {
                result += ",row0:\(table.rect(ofRow: 0)),cell0:\(table.frameOfCell(atColumn: 0, row: 0))"
            }
        }
        if let document = scroll.documentView {
            let measurements = descendants(document).compactMap { $0 as? ActivityFeedNativeCell }.filter(\.isCoherentNativeMeasurement)
            let documentFrames = measurements.map { $0.convert($0.bounds, to: document) }
            result += " measurementFrames=\(documentFrames)"
        }
        return result
    }

    func captureBitmap() throws -> NSBitmapImageRep {
        let screen = try #require(window.screen ?? NSScreen.screens.first)
        let frame = window.frame.integral
        let screenFrame = screen.frame
        let rect = CGRect(x: frame.minX, y: screenFrame.maxY - frame.maxY, width: frame.width, height: frame.height)
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pb-activity-baseline-\(UUID().uuidString).png")
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", raw.path]
        try process.run(); process.waitUntilExit(); try #require(process.terminationStatus == 0)
        defer { try? FileManager.default.removeItem(at: raw) }
        let image = try #require(NSImage(contentsOf: raw))
        return try #require(image.representations.compactMap { $0 as? NSBitmapImageRep }.first)
    }

    func capturePausedTop() async throws -> NSBitmapImageRep {
        let scroll = try #require(descendants(controller.view).compactMap { $0 as? NSScrollView }.first)
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        await waitUntil(timeout: 5) {
            controller.view.layoutSubtreeIfNeeded()
            return abs(scroll.documentVisibleRect.minY) < 1
        }
        try #require(abs(scroll.documentVisibleRect.minY) < 1, "(name): top capture did not settle")
        return try captureBitmap()
    }

    func write(_ bitmap: NSBitmapImageRep, metrics: String, nameSuffix: String = "", output: URL) throws {
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: output.appendingPathComponent(name + nameSuffix + ".png"))
        try metrics.write(to: output.appendingPathComponent(name + nameSuffix + ".metrics.txt"), atomically: true, encoding: .utf8)
    }

    func close() { window.contentViewController = nil; window.close() }
    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
}

private func bitmapHasInk(_ bitmap: NSBitmapImageRep) -> Bool {
    stride(from: 0, to: bitmap.pixelsHigh, by: max(1, bitmap.pixelsHigh / 40)).contains { y in
        stride(from: 0, to: bitmap.pixelsWide, by: max(1, bitmap.pixelsWide / 40)).contains { x in
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
            return color.alphaComponent > 0.01 && (color.redComponent + color.greenComponent + color.blueComponent) < 2.85
        }
    }
}

private struct ListHierarchyProbe: NSViewRepresentable {
    let reportURL: URL
    let box = ProbeBox()
    func makeNSView(context: Context) -> ProbeView { ProbeView(reportURL: reportURL, box: box) }
    func updateNSView(_ nsView: ProbeView, context: Context) { nsView.inspect() }

    final class ProbeView: NSView {
        let reportURL: URL
        let box: ProbeBox
        init(reportURL: URL, box: ProbeBox) { self.reportURL = reportURL; self.box = box; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); inspect() }
        func inspect() {
            guard window != nil else { return }
            var lines = ["probe=\(type(of: self))"]
            var node: NSView? = self
            var nearestScroll: NSScrollView?
            while let current = node {
                lines.append("ancestor=\(type(of: current)) frame=\(current.frame)")
                if nearestScroll == nil, let scroll = current as? NSScrollView { nearestScroll = scroll }
                node = current.superview
            }
            if let scroll = nearestScroll {
                lines.append("nearestScroll=\(type(of: scroll)) document=\(String(describing: scroll.documentView.map { type(of: $0) }))")
                lines.append(
                    "scrollFrame=\(scroll.frame) scrollBounds=\(scroll.bounds) "
                        + "clipFrame=\(scroll.contentView.frame) clipBounds=\(scroll.contentView.bounds)"
                )
                if let document = scroll.documentView {
                    lines.append("documentFrame=\(document.frame) documentBounds=\(document.bounds)")
                }
                let tables = descendants(scroll).compactMap { $0 as? NSTableView }
                lines.append("ownedTables=\(tables.map { String(describing: type(of: $0)) })")
                for (index, table) in tables.enumerated() {
                    lines.append(
                        "table[\(index)] frame=\(table.frame) bounds=\(table.bounds) "
                            + "style=\(table.style.rawValue) rowHeight=\(table.rowHeight) "
                            + "intercellSpacing=\(table.intercellSpacing) rows=\(table.numberOfRows) "
                            + "columns=\(table.numberOfColumns) "
                            + "column0=\(table.numberOfColumns > 0 ? table.rect(ofColumn: 0) : .zero)"
                    )
                    if table.numberOfRows > 0, table.numberOfColumns > 0 {
                        lines.append("table[\(index)] row0=\(table.rect(ofRow: 0)) cell0=\(table.frameOfCell(atColumn: 0, row: 0))")
                    }
                }
            } else { lines.append("nearestScroll=nil") }
            try? lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
            box.didObserve = true
        }

        private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    }

    final class ProbeBox {
        var didObserve = false
    }
}
