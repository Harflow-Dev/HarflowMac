import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ParallelColumnsRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark], [RenderState.loaded, .nonresident, .skeleton])
    func givenAParallelLane_whenRenderedAtItsActualBoundary_thenItsBottomCornersAreTheChromeSurface(
        scheme: ColorScheme, state: RenderState
    ) throws {
        for chrome in [ParallelColumnChrome.lane, .inspector] {
            try assertCorners(scheme: scheme, state: state, chrome: chrome)
        }
    }

    private func assertCorners(scheme: ColorScheme, state: RenderState, chrome: ParallelColumnChrome) throws {
        // given — render the production ParallelColumnsContent, including its actual resident and
        // placeholder branches. The outer corners are the observable flush boundary; activity cards
        // inside the lane are intentionally not sampled here.
        var model = makeModel(state: state)
        model.chrome = chrome
        let width = ParallelLayout.minimumColumnWidth
        let view = ParallelColumnsContent(
            columns: [model], availableSize: CGSize(width: width, height: 320),
            stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in }
        )
        let surface: Color = chrome == .lane ? TaskScreenStyle.Colors.pageBackground.color : Color.cardFill
        let image = try render(view.frame(width: width, height: 320), scheme: scheme)
        let reference = try render(surface.frame(width: width, height: 320), scheme: scheme)
        let clearReference = try render(Color.clear.frame(width: width, height: 320), scheme: scheme)
        let windowReference = try render(Color.windowBG.frame(width: width, height: 320), scheme: scheme)

        // when / then — a rounded pane would expose the transparent parent at both bottom corners. A
        // square flush lane paints its surface through the full boundary in both modes. The right
        // sample sits inside the lane, off the 1 pt separator that follows it.
        for point in [CGPoint(x: 2, y: image.pixelsHigh - 1),
                      CGPoint(x: image.pixelsWide - 3, y: image.pixelsHigh - 1)] {
            let actual = try #require(image.colorAt(x: Int(point.x), y: Int(point.y)))
            let expected = try #require(reference.colorAt(x: Int(point.x), y: Int(point.y)))
            let clear = try #require(clearReference.colorAt(x: Int(point.x), y: Int(point.y)))
            #expect(close(actual, expected), "\(state) \(scheme) \(chrome) corner must match the chrome surface")
            #expect(!close(actual, clear), "\(state) \(scheme) \(chrome) corner must not be clear")
            if chrome == .inspector {
                let window = try #require(windowReference.colorAt(x: Int(point.x), y: Int(point.y)))
                #expect(!close(actual, window), "\(state) \(scheme) inspector corner must not be windowBG")
            }
        }
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenTwoLoadedLanes_whenRendered_thenTheSeparatorIsOnePointOfBorderAtTheLaneStride(scheme: ColorScheme) throws {
        // given
        let width = ParallelTestGeometry.laneStride * 2
        let first = makeModel(id: "first", state: .loaded)
        let second = makeModel(id: "second", state: .loaded)
        let view = ParallelColumnsContent(
            columns: [first, second], availableSize: CGSize(width: width, height: 320),
            stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in }
        )
        let image = try render(view.frame(width: width, height: 320), scheme: scheme)

        // when / then — lane, then a 1 pt `--border` separator, then the next lane at the original stride.
        let laneWidth = ParallelLayout.columnWidth(memberCount: 2, availableWidth: width)
        #expect(laneWidth == ParallelLayout.minimumColumnWidth)
        #expect(ParallelLayout.dividerWidth == 1)
        let y = image.pixelsHigh - 3
        let border = try render(TaskScreenStyle.Colors.border.color.frame(width: 4, height: 4), scheme: scheme)
        let expectedBorder = try #require(border.colorAt(x: 1, y: 1))
        let separator = try #require(image.colorAt(x: Int(laneWidth), y: y))
        let left = try #require(image.colorAt(x: Int(laneWidth) - 2, y: y))
        let right = try #require(image.colorAt(x: Int(laneWidth) + 3, y: y))
        #expect(close(separator, expectedBorder), "the separator is --border")
        #expect(!close(left, separator) && !close(right, separator))
        let background = try render(TaskScreenStyle.Colors.pageBackground.color.frame(width: 4, height: 4), scheme: scheme)
        let expectedBackground = try #require(background.colorAt(x: 1, y: 1))
        #expect(close(left, expectedBackground) && close(right, expectedBackground), "both lanes are filled with --bg")
    }

    @Test func givenAnInspectorColumn_whenRendered_thenItKeepsTheCardFillStatusStripAndSystemDivider() throws {
        // given
        var model = makeModel(state: .loaded)
        model.chrome = .inspector
        let width = ParallelLayout.minimumColumnWidth
        let view = ParallelColumnsContent(
            columns: [model], availableSize: CGSize(width: width, height: 320),
            stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in }
        )

        // when
        let image = try render(view.frame(width: width, height: 320), scheme: .light)
        let stripColor = try #require(ParallelLaneTint.color(for: model.task.status))
        let strip = try render(stripColor.frame(width: 4, height: 4), scheme: .light)

        // then — a 3 pt status-tinted strip across the top edge; the old geometry is unchanged.
        let top = try #require(image.colorAt(x: 100, y: 1))
        #expect(close(top, try #require(strip.colorAt(x: 1, y: 1))))
        let below = try #require(image.colorAt(x: 100, y: 6))
        #expect(!close(below, top))
        #expect(HfRadius.Metrics.parallelLaneStatusStripHeight == 3)
    }

    @Test func givenALongSettledResult_whenTheInspectorHostsIt_thenResultIsBoundedAndActivityRemainsScrollable() async throws {
        // given — a real lane with a long snapshot result, a long activity feed, and the existing
        // settled-session terminal action. No test-only production hook is used.
        _ = NSApplication.shared
        let task = TaskInfo(.object([
            "task_id": .string("long-result"), "backend": .string("claude"),
            "status": .string("completed"), "session_id": .string("session")
        ]))!
        let rows = (0 ..< 140).map { index in
            ConversationTimelineRow(id: "row-\(index)", taskID: task.taskID, timestamp: nil,
                kind: .item(PreviewFixtures.textItem(String(repeating: "Long activity output remains reachable. ", count: 8), seq: index)), live: false)
        }
        let model = ParallelColumnModel(
            id: task.taskID, task: task, title: "Long result", subtitle: "Claude", isBusy: false,
            outcomeMessage: nil, showPrompt: false, rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
            summary: String(repeating: "A long settled result remains independently readable.\n", count: 100) + "RESULT-END",
            onTapTakeover: {}, onTapOpenTask: {}
        )
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: ParallelColumnView(model: model.withChrome(.inspector)).frame(width: 520, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        }

        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) {
            host.layoutSubtreeIfNeeded()
            return hasCommittedActivityOverflow(in: host)
        }

        // then — the result gets its own bounded viewport, while the activity feed still owns a
        // separate scroll view and the existing terminal action remains an AX button.
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        let resultScroll = try #require(scrolls.first { $0.frame.height <= HfRadius.Metrics.parallelResultMaximumHeight + 2 })
        let activityScroll = try #require(scrolls.first { $0 !== resultScroll && $0.hasVerticalScroller })
        #expect(resultScroll.frame.height <= HfRadius.Metrics.parallelResultMaximumHeight + 2)
        #expect((resultScroll.documentView?.bounds.height ?? 0) > resultScroll.contentView.bounds.height)
        #expect((activityScroll.documentView?.bounds.height ?? 0) > activityScroll.contentView.bounds.height)
        #expect(resultScroll.scrollerStyle == .overlay)
        #expect(resultScroll.verticalScroller?.controlSize == .small)
        let resultDocumentMaxY = resultScroll.documentView?.bounds.maxY ?? 0
        let resultScrollOrigin = max(resultScroll.documentView?.bounds.minY ?? 0,
                                     resultDocumentMaxY - resultScroll.contentView.bounds.height)
        resultScroll.contentView.scroll(to: CGPoint(x: 0, y: resultScrollOrigin))
        resultScroll.reflectScrolledClipView(resultScroll.contentView)
        #expect(abs(resultScroll.documentVisibleRect.maxY - resultDocumentMaxY) < 3)
        #expect(allAccessibilityObjects(in: host).contains {
            accessibilityString($0, "accessibilityLabel")?.contains("RESULT-END") == true
                || accessibilityString($0, "accessibilityValue")?.contains("RESULT-END") == true
        })
    }

    @Test func givenALongSettledResult_whenALaneHostsIt_thenThereIsNoResultCalloutAndTheMenuIsAccessible() async throws {
        // given
        _ = NSApplication.shared
        let task = TaskInfo(.object([
            "task_id": .string("lane-result"), "backend": .string("claude"),
            "status": .string("completed"), "session_id": .string("session")
        ]))!
        let rows = (0 ..< 40).map { index in
            ConversationTimelineRow(id: "row-\(index)", taskID: task.taskID, timestamp: nil,
                kind: .item(PreviewFixtures.textItem("Activity row \(index)", seq: index)), live: false)
        }
        let model = ParallelColumnModel(
            id: task.taskID, task: task, title: "Lane result", subtitle: "Claude", isBusy: false,
            outcomeMessage: nil, showPrompt: false, rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
            isLoading: false, summary: "LANE-RESULT-TEXT", onTapTakeover: nil, onTapOpenTask: {})
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let host = NSHostingView(rootView: ParallelColumnView(model: model).frame(width: 520, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        }

        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) { host.layoutSubtreeIfNeeded(); return !descendants(host).compactMap { $0 as? NSScrollView }.isEmpty }

        // then — the result is not drawn in a lane (the end row carries the outcome); the actions menu stays reachable
        #expect(!allAccessibilityObjects(in: host).contains { object in
            ["accessibilityLabel", "accessibilityValue"].contains { accessibilityString(object, $0)?.contains("LANE-RESULT-TEXT") == true }
        })
        #expect(!allAccessibilityObjects(in: host).contains { accessibilityString($0, "accessibilityLabel") == "Result" })
        #expect(allAccessibilityObjects(in: host).contains { object in
            ["accessibilityLabel", "accessibilityTitle"].contains { accessibilityString(object, $0) == "Lane actions" }
        })
        #expect(!allAccessibilityObjects(in: host).contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                accessibilityString(object, $0)?.contains("Take over in terminal") == true
            }
        }, "a lane offers no inline Take over")
    }

    @Test(arguments: ["", " \n\t "])
    func givenAnEmptyOrWhitespaceSettledResult_whenRendered_thenItMatchesTheMissingResultSurface(_ summary: String) throws {
        // given — the projection retains raw snapshot data, but the result callout omits content
        // that has no readable characters.
        let task = TaskInfo(.object([
            "task_id": .string("empty-result"), "backend": .string("claude"), "status": .string("completed")
        ]))!
        func model(summary: String?) -> ParallelColumnModel {
            ParallelColumnModel(id: task.taskID, task: task, title: "Result", subtitle: "Claude", isBusy: false,
                outcomeMessage: nil, showPrompt: false, rows: [], activityRows: [], liveStep: nil,
                isLoading: false, summary: summary, onTapTakeover: {}, onTapOpenTask: {})
        }

        // when
        let missing = try render(ParallelColumnView(model: model(summary: nil)).frame(width: 520, height: 300), scheme: .light)
        let blank = try render(ParallelColumnView(model: model(summary: summary)).frame(width: 520, height: 300), scheme: .light)

        // then — rendering equality follows observable content, not the raw optional's presence.
        #expect(missing.tiffRepresentation == blank.tiffRepresentation)
    }

    @Test func givenAShortSettledResult_whenTheInspectorHostsIt_thenResultViewportHugsContentAndKeepsNativeThinChrome() async throws {
        // given
        _ = NSApplication.shared
        let task = TaskInfo(.object([
            "task_id": .string("short-result"), "backend": .string("claude"),
            "status": .string("completed"), "session_id": .string("session")
        ]))!
        let rows = (0 ..< 100).map { index in
            ConversationTimelineRow(id: "row-\(index)", taskID: task.taskID, timestamp: nil,
                kind: .item(PreviewFixtures.textItem("Activity row \(index)", seq: index)), live: false)
        }
        let model = ParallelColumnModel(id: task.taskID, task: task, title: "Short result", subtitle: "Claude",
            isBusy: false, outcomeMessage: nil, showPrompt: false, rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
            summary: "Short result", onTapTakeover: {}, onTapOpenTask: {})
        let host = NSHostingView(rootView: ParallelColumnView(model: model.withChrome(.inspector)).frame(width: 520, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) { host.layoutSubtreeIfNeeded(); return !descendants(host).compactMap { $0 as? NSScrollView }.isEmpty }

        // then
        let result = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.frame.height <= HfRadius.Metrics.parallelResultMaximumHeight + 2
        })
        #expect(result.frame.height < HfRadius.Metrics.parallelResultMaximumHeight)
        #expect((result.documentView?.bounds.height ?? 0) <= result.contentView.bounds.height + 3)
        #expect(result.scrollerStyle == .overlay)
        #expect(result.verticalScroller?.controlSize == .small)
    }

    // MARK: - Lane head

    private func laneHeadModel(title: String = "Audit what the preload bridge exposes", notice: String? = nil, adopt: Bool = false,
                               chrome: ParallelColumnChrome = .lane) -> ParallelColumnModel {
        var model = makeModel(id: "head", state: .loaded)
        model = ParallelColumnModel(id: model.id, task: model.task, title: title, subtitle: "Codex · tmp", isBusy: false,
            outcomeMessage: nil, showPrompt: false, rows: model.rows, activityRows: model.activityRows, liveStep: nil,
            isLoading: false, summary: nil, onTapTakeover: chrome == .inspector ? {} : nil, onTapOpenTask: {})
        model.chrome = chrome
        model.cachedHistoryNotice = notice
        if adopt { model.onAdoptWindow = {} }
        return model
    }

    private func frameOf(_ fixture: RedesignHost, _ label: String) throws -> CGRect {
        let element = try #require(fixture.element(label))
        return try #require(fixture.frame(element))
    }

    private func mount(_ model: ParallelColumnModel, width: CGFloat = 380, height: CGFloat = 600) -> RedesignHost {
        RedesignHost(ParallelColumnView(model: model).frame(width: width, height: height), size: CGSize(width: width, height: height))
    }

    @Test func givenALaneHead_whenMounted_thenTheMenuIsA26PointControlAtTheHeadPadding() async throws {
        // given
        let fixture = mount(laneHeadModel())
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Lane actions") != nil && fixture.element("Audit what the preload bridge exposes") != nil }

        // then — 16 pt side padding, 26 x 26 menu, title after the 16 pt glyph and 8 pt gap
        let menu = try frameOf(fixture, "Lane actions")
        let title = try frameOf(fixture, "Audit what the preload bridge exposes")
        #expect(abs(menu.width - 26) < 1.5 && abs(menu.height - 26) < 1.5, "menu \(menu)")
        #expect(abs(menu.maxX - (380 - 16)) < 1.5, "menu trailing edge \(menu.maxX)")
        #expect(abs(title.minX - (16 + 16 + 8)) < 1.5, "title leading edge \(title.minX)")
        #expect(fixture.element("Take over in terminal") == nil)
        #expect(fixture.element("Open task") == nil, "Open task lives inside the menu, not in the head")
    }

    @Test func givenALongTitle_whenMountedAtTheLaneFloor_thenItWrapsToTwoLinesAndNoFurther() async throws {
        // given
        let short = mount(laneHeadModel(title: "Short"), width: 360)
        defer { short.close() }
        let longTitle = String(repeating: "Check the allow-list and sandbox settings ", count: 8)
        let long = mount(laneHeadModel(title: longTitle), width: 360)
        defer { long.close() }

        // when
        await short.settle { short.element("Short") != nil }
        await long.settle { long.element(longTitle) != nil }

        // then
        let one = try frameOf(short, "Short").height
        let two = try frameOf(long, longTitle).height
        #expect(abs(two - 2 * one) < 3, "one line \(one), long title \(two)")
    }

    @Test func givenNoHistoryNotice_whenMounted_thenNoBoundaryLineIsDrawn() async {
        // given
        let fixture = mount(laneHeadModel())
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Lane actions") != nil }

        // then
        #expect(fixture.element("Available captured history") == nil)
        #expect(fixture.element("History boundary") == nil)
    }

    @Test func givenAHistoryNotice_whenMounted_thenTheBoundaryBlockAndItsButtonAreDrawn() async {
        // given
        let notice = "Observation session changed · cached history is not current. Replace this window to load current activity."
        let withButton = mount(laneHeadModel(notice: notice, adopt: true))
        defer { withButton.close() }
        let withoutButton = mount(laneHeadModel(notice: notice, adopt: false))
        defer { withoutButton.close() }

        // when
        await withButton.settle { withButton.element("History boundary") != nil }
        await withoutButton.settle { withoutButton.element("History boundary") != nil }

        // then
        #expect(withButton.element(notice) != nil)
        #expect(withButton.element("Load current activity") != nil)
        #expect(withoutButton.element("Load current activity") == nil)
    }

    @Test func givenTheInspector_whenMounted_thenItKeepsItsHeaderTakeoverAndDefaultHistoryLine() async {
        // given
        var model = laneHeadModel(chrome: .inspector)
        model = ParallelColumnModel(id: model.id, task: TaskInfo(.object([
            "task_id": .string("head"), "backend": .string("codex"), "status": .string("completed"),
            "repo_path": .string("/tmp"), "session_id": .string("s")]))!, title: "Inspector", subtitle: "Codex · tmp", isBusy: false,
            outcomeMessage: nil, showPrompt: false, rows: model.rows, activityRows: model.activityRows, liveStep: nil,
            isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        model.chrome = .inspector
        let fixture = mount(model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Available captured history") != nil }

        // then
        #expect(fixture.element("Take over in terminal") != nil)
        #expect(fixture.element("Open task") != nil)
        #expect(fixture.element("Lane actions") == nil)
    }

    enum RenderState: String, CaseIterable, CustomStringConvertible {
        case loaded, nonresident, skeleton
        var description: String { rawValue }
    }

    private func hasCommittedActivityOverflow(in host: NSView) -> Bool {
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        guard scrolls.count >= 2,
              let activity = scrolls.first(where: { $0.documentView is ActivityFeedNativeTableView }),
              let table = activity.documentView as? ActivityFeedNativeTableView,
              table.numberOfRows >= 100, table.owner?.positioned == true else { return false }
        // Native scroll containers exist before their committed rows are realized.
        return table.bounds.height > activity.contentView.bounds.height
            && descendants(table).contains {
                ($0 as? ActivityFeedNativeCell)?.isCoherentNativeMeasurement == true
            }
    }

    private func makeModel(id: String = "lane", state: RenderState) -> ParallelColumnModel {
        let task = TaskInfo(.object([
            "task_id": .string(id), "backend": .string("codex"), "status": .string("completed"),
            "repo_path": .string("/tmp")
        ]))!
        let row = ConversationTimelineRow(id: "row", taskID: id, timestamp: nil,
                                          kind: .item(PreviewFixtures.textItem("Result", seq: 1)), live: false)
        var model = ParallelColumnModel(
            id: id, task: task, title: "Lane", subtitle: "Codex", isBusy: false,
            outcomeMessage: nil, showPrompt: false, rows: [row],
            activityRows: ActivityRowsBuilder.build(from: [row]), liveStep: nil,
            isLoading: state == .skeleton, summary: nil,
            onTapTakeover: {}, onTapOpenTask: {}
        )
        model.isResident = state != .nonresident
        return model
    }

    private func render(_ view: some View, scheme: ColorScheme) throws -> NSBitmapImageRep {
        let appearance = try #require(NSAppearance(named: scheme == .light ? .aqua : .darkAqua))
        var image: CGImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme).environment(\.hfReduceMotionOverride, true))
            renderer.scale = 1
            image = renderer.cgImage
        }
        return try #require(image).bitmapImageRep()
    }

    private func close(_ actual: NSColor, _ expected: NSColor) -> Bool {
        guard let actual = actual.usingColorSpace(.sRGB), let expected = expected.usingColorSpace(.sRGB) else { return false }
        return abs(actual.redComponent - expected.redComponent) < 0.005
            && abs(actual.greenComponent - expected.greenComponent) < 0.005
            && abs(actual.blueComponent - expected.blueComponent) < 0.005
    }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }

    private func allAccessibilityObjects(in root: NSView) -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        for view in descendants(root) {
            for object in accessibilityTree(view) where seen.insert(ObjectIdentifier(object)).inserted { result.append(object) }
        }
        return result
    }

    private func accessibilityTree(_ object: NSObject) -> [NSObject] {
        var result = [object]
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [Any] else { return result }
        for child in children { if let child = child as? NSObject { result += accessibilityTree(child) } }
        return result
    }

    private func accessibilityString(_ object: NSObject, _ key: String) -> String? {
        let selector = NSSelectorFromString(key)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }
}

private extension CGImage {
    func bitmapImageRep() throws -> NSBitmapImageRep {
        try #require(NSBitmapImageRep(cgImage: self))
    }
}
