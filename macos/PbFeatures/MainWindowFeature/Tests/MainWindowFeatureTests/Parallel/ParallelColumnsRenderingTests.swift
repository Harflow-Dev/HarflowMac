import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct ParallelColumnsRenderingTests {
    @Test(arguments: [ColorScheme.light, .dark], [RenderState.loaded, .nonresident, .skeleton])
    func givenAParallelLane_whenRenderedAtItsActualBoundary_thenItsBottomCornersAreTheSquareLaneSurface(
        scheme: ColorScheme, state: RenderState
    ) throws {
        // given — render the production ParallelColumnsContent, including its actual resident and
        // placeholder branches. The outer corners are the amendment's observable flush boundary;
        // activity cards inside the lane are intentionally not sampled here.
        let model = makeModel(state: state)
        let view = ParallelColumnsContent(
            columns: [model], availableSize: CGSize(width: 420, height: 320),
            stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in }
        )
        let image = try render(view.frame(width: 420, height: 320), scheme: scheme)
        let cardReference = try render(Color.cardFill.frame(width: 420, height: 320), scheme: scheme)
        let windowReference = try render(Color.windowBG.frame(width: 420, height: 320), scheme: scheme)
        let clearReference = try render(Color.clear.frame(width: 420, height: 320), scheme: scheme)

        // when / then — a rounded pane would expose the transparent parent at both bottom
        // corners. A square flush lane paints cardFill through the full boundary in both modes.
        for point in [CGPoint(x: 0, y: image.pixelsHigh - 1),
                      CGPoint(x: image.pixelsWide - 1, y: image.pixelsHigh - 1)] {
            let actual = try #require(image.colorAt(x: Int(point.x), y: Int(point.y)))
            let expected = try #require(cardReference.colorAt(x: Int(point.x), y: Int(point.y)))
            let window = try #require(windowReference.colorAt(x: Int(point.x), y: Int(point.y)))
            let clear = try #require(clearReference.colorAt(x: Int(point.x), y: Int(point.y)))
            #expect(close(actual, expected), "(state) (scheme) corner must match cardFill")
            #expect(!close(actual, window), "(state) (scheme) corner must not be windowBG")
            #expect(!close(actual, clear), "(state) (scheme) corner must not be clear")
        }
    }

    @Test func givenTwoLoadedLanes_whenRendered_thenTheDividerRemainsAtTheOriginalStride() throws {
        // given
        let first = makeModel(id: "first", state: .loaded)
        let second = makeModel(id: "second", state: .loaded)
        let view = ParallelColumnsContent(
            columns: [first, second], availableSize: CGSize(width: 900, height: 320),
            stateForColumn: { _ in ParallelColumnUIState() }, onViewport: { _, _ in }
        )
        let image = try render(view.frame(width: 900, height: 320), scheme: .light)

        // when / then — the divider is still the existing column stride, independent of whether
        // the outer lane surround is rounded or flush.
        let width = ParallelLayout.columnWidth(memberCount: 2, availableWidth: 900)
        #expect(width == 449)
        #expect(ParallelLayout.dividerWidth == 1)
        let divider = try #require(image.colorAt(x: Int(width), y: image.pixelsHigh / 2))
        let left = try #require(image.colorAt(x: Int(width) - 1, y: image.pixelsHigh / 2))
        let right = try #require(image.colorAt(x: Int(width) + 1, y: image.pixelsHigh / 2))
        #expect(!close(divider, left) || !close(divider, right))
    }

    @Test func givenALongSettledResult_whenHosted_thenResultIsBoundedActivityRemainsScrollableAndTerminalActionRemainsAccessible() async throws {
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
            outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
            summary: String(repeating: "A long settled result remains independently readable.\n", count: 100) + "RESULT-END",
            onTapTakeover: {}, onTapOpenTask: {}
        )
        let previousEnhanced = NSApplication.shared.accessibilityAttributeValue(NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        let host = NSHostingView(rootView: ParallelColumnView(model: model).frame(width: 520, height: 700))
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
            return descendants(host).compactMap { $0 as? NSScrollView }.count >= 2
        }

        // then — the result gets its own bounded viewport, while the activity feed still owns a
        // separate scroll view and the existing terminal action remains an AX button.
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        let resultScroll = try #require(scrolls.first { $0.frame.height <= PbRadius.Metrics.parallelResultMaximumHeight + 2 })
        let activityScroll = try #require(scrolls.first { $0 !== resultScroll && $0.hasVerticalScroller })
        #expect(resultScroll.frame.height <= PbRadius.Metrics.parallelResultMaximumHeight + 2)
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
        #expect(allAccessibilityObjects(in: host).contains { object in
            accessibilityString(object, "accessibilityRole") == NSAccessibility.Role.button.rawValue
                && ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                    accessibilityString(object, $0)?.contains("Take over in terminal") == true
                }
        })
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
                outcomeMessage: nil, showPrompt: false, prompt: nil, rows: [], activityRows: [], liveStep: nil,
                isLoading: false, summary: summary, onTapTakeover: {}, onTapOpenTask: {})
        }

        // when
        let missing = try render(ParallelColumnView(model: model(summary: nil)).frame(width: 520, height: 300), scheme: .light)
        let blank = try render(ParallelColumnView(model: model(summary: summary)).frame(width: 520, height: 300), scheme: .light)

        // then — rendering equality follows observable content, not the raw optional's presence.
        #expect(missing.tiffRepresentation == blank.tiffRepresentation)
    }

    @Test func givenAShortSettledResult_whenHosted_thenResultViewportHugsContentAndKeepsNativeThinChrome() async throws {
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
            isBusy: false, outcomeMessage: nil, showPrompt: false, prompt: nil, rows: rows,
            activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil, isLoading: false,
            summary: "Short result", onTapTakeover: {}, onTapOpenTask: {})
        let host = NSHostingView(rootView: ParallelColumnView(model: model).frame(width: 520, height: 700))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.contentView = nil; window.close() }

        // when
        await DisplayFrames.waitForPresentedFrame()
        await waitUntil(timeout: 5) { host.layoutSubtreeIfNeeded(); return !descendants(host).compactMap { $0 as? NSScrollView }.isEmpty }

        // then
        let result = try #require(descendants(host).compactMap { $0 as? NSScrollView }.first {
            $0.frame.height <= PbRadius.Metrics.parallelResultMaximumHeight + 2
        })
        #expect(result.frame.height < PbRadius.Metrics.parallelResultMaximumHeight)
        #expect((result.documentView?.bounds.height ?? 0) <= result.contentView.bounds.height + 3)
        #expect(result.scrollerStyle == .overlay)
        #expect(result.verticalScroller?.controlSize == .small)
    }

    enum RenderState: String, CaseIterable, CustomStringConvertible {
        case loaded, nonresident, skeleton
        var description: String { rawValue }
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
            outcomeMessage: nil, showPrompt: false, prompt: nil, rows: [row],
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
            let renderer = ImageRenderer(content: view.environment(\.colorScheme, scheme))
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
