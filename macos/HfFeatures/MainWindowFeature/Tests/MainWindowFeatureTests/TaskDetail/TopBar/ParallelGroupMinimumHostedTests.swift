import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - ParallelGroupMinimumHostedTests

/// The minimum window (1000 x 620) of a Parallel group in the production shell: the lane viewport, and the dot that
/// stands in for an enforcement sentence that did not fit. Needs the AppKit host.
@MainActor @Suite(.serialized) struct ParallelGroupMinimumHostedTests {
    private static let sentence = "Enforced for every agent here: Network: not controlled."

    private struct Shell {
        let window: NSWindow
        let writer: TopBarFixtures.Writer
    }

    private func shell(size: CGSize, empty: Bool = false) async -> Shell {
        _ = NSApplication.shared
        let vm = ParallelGroupTopBarHostedTests.GroupScreenVM()
        vm.isEmpty = empty
        if empty { vm.columns = [] }
        let coordinator = MainWindowNavigationCoordinatorMock()
        coordinator.parallelBuilder = { _ in ParallelView(vm, initiallyPrepared: true).id("group").eraseToAnyView() }
        coordinator.selection = .group("release")
        let writer = TopBarFixtures.Writer()
        let tag = TaskTopBarHolder.Tag(writer: ObjectIdentifier(writer), subject: .group("release"))
        coordinator.topBar.setShownSubject(.group("release"))
        let counts = ParallelStatusCounts(tasks: (empty ? [] : ["running", "completed", "completed"]).enumerated().map {
            TaskInfo(.object(["task_id": .string("t\($0.offset)"), "status": .string($0.element)]))!
        })
        coordinator.topBar.publish(GroupTopBarContent(title: "release", badge: TaskBadgeModel.group(counts), meta: empty ? nil : Self.sentence), tag: tag)
        coordinator.topBar.activate(tag)
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator).environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: size.width, height: size.height))
        var passes = 0
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 120
        }
        return Shell(window: window, writer: writer)
    }

    private func close(_ shell: Shell) { shell.window.contentViewController = nil; shell.window.close() }

    private func views(_ root: NSView) -> [NSView] { [root] + root.subviews.flatMap(views) }

    private func dot(_ window: NSWindow) -> TopBarMetaDotView? {
        let roots: [NSView] = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap(\.self)
        return roots.flatMap(views).compactMap { $0 as? TopBarMetaDotView }.first
    }

    private func activeDot(_ window: NSWindow) -> TopBarMetaDotView? { dot(window).flatMap { $0.isHidden ? nil : $0 } }

    /// The labels and values the accessibility tree exposes, each with its frame, deduplicated by frame so one element
    /// counts once however many proxy objects stand for it.
    private func accessibilityTexts(_ window: NSWindow) -> [(text: String, frame: CGRect)] {
        var found: [(text: String, frame: CGRect)] = []
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = (window.toolbar?.items.compactMap(\.view) ?? []) + [window.contentView].compactMap(\.self)
        while let next = queue.popLast(), seen.count < 30000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            let frameSelector = NSSelectorFromString("accessibilityFrame")
            for key in ["accessibilityLabel", "accessibilityValue"] {
                let selector = NSSelectorFromString(key)
                guard next.responds(to: selector), let text = next.perform(selector)?.takeUnretainedValue() as? String, !text.isEmpty else { continue }
                let frame = (next as? NSAccessibilityProtocol)?.accessibilityFrame() ?? (next.responds(to: frameSelector) ? .zero : .zero)
                found.append((text, frame.integral))
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return found
    }

    private func accessibilityLabels(_ window: NSWindow) -> [String] { accessibilityTexts(window).map(\.text) }

    /// How many distinct elements (by frame) carry `text`.
    private func elementCount(_ window: NSWindow, _ text: String) -> Int {
        // An entry without a frame is the same element seen through a proxy object.
        Set(accessibilityTexts(window).filter { $0.text == text && $0.frame != .zero }.map { "\($0.frame)" }).count
    }

    private func settle(_ window: NSWindow, passes count: Int = 20) async {
        var passes = 0
        await waitUntil(timeout: 3) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= count
        }
    }

    @Test func givenTheMinimumWindow_whenMounted_thenTwoWholeLanesAndAPeekOfTheThirdShowAndTheTitleIsWhole() async throws {
        // given / when
        let mounted = await shell(size: CGSize(width: 1000, height: 620))
        defer { close(mounted) }

        // then — the lane viewport is the detail pane beside the floating sidebar (728 pt): two whole 361 pt lanes plus a peek
        let content = try #require(mounted.window.contentView)
        let scrolls = views(content).compactMap { $0 as? NSScrollView }
        let scroll = try #require(scrolls.first { $0.hasHorizontalScroller && ($0.documentView?.frame.height ?? 0) > 300 })
        let viewport = scroll.contentView.bounds.width - scroll.contentInsets.left
        let peek = viewport - 2 * (ParallelLayout.minimumColumnWidth + ParallelLayout.dividerWidth)
        #expect(peek > 0, "the third lane intersects the viewport, so it is resident: peek \(peek)")
        #expect(abs(peek - 6) <= 1, "measured peek in the real shell: \(peek)")
        #expect(accessibilityLabels(mounted.window).contains("release"), "the title is whole")
    }

    @Test func givenTheMinimumWindow_whenMounted_thenTheSentenceIsOnlyTheDotsLabelAndTheDotIsSixteenSquare() async throws {
        // given / when
        let mounted = await shell(size: CGSize(width: 1000, height: 620))
        defer { close(mounted) }

        // then
        let dot = try #require(activeDot(mounted.window), "no dot at the minimum window")
        let frame = dot.convert(dot.bounds, to: nil)
        #expect(abs(frame.width - 16) <= 0.5 && abs(frame.height - 16) <= 0.5, "dot \(frame)")
        let sentenceElements = accessibilityTexts(mounted.window).filter { $0.text == Self.sentence }
        #expect(elementCount(mounted.window, Self.sentence) == 1, "the sentence is exposed once: \(sentenceElements)")
        #expect(dot.accessibilityLabel() == Self.sentence)
        #expect(dot.toolTip == nil, "no .help tooltip")
    }

    @Test func givenTheDot_whenItBecomesFirstResponder_thenThePopoverShowsEscapeDismissesItAndItDoesNotReturnUntilFocusLeavesAndReturns() async throws {
        // given
        let mounted = await shell(size: CGSize(width: 1000, height: 620))
        defer { close(mounted) }
        let dot = try #require(activeDot(mounted.window))

        // when — focus enters
        #expect(mounted.window.makeFirstResponder(dot))
        await settle(mounted.window)

        // then — the popover is shown and does not take key focus
        #expect(dot.isPopoverShown)
        #expect(mounted.window.firstResponder === dot, "the popover must not take key focus")

        // when — Escape
        dot.cancelOperation(nil)
        await settle(mounted.window)

        // then — dismissed while focus stays
        #expect(dot.isPopoverShown == false)
        dot.mouseEntered(with: NSEvent())
        #expect(dot.isPopoverShown == false)

        // when — focus leaves and returns
        #expect(mounted.window.makeFirstResponder(nil))
        dot.mouseExited(with: NSEvent())
        await settle(mounted.window)
        #expect(mounted.window.makeFirstResponder(dot))
        await settle(mounted.window)

        // then
        #expect(dot.isPopoverShown)
        _ = mounted.window.makeFirstResponder(nil)
    }

    @Test func givenAnEmptyGroup_whenMountedAtTheMinimumWindow_thenThereIsNoDot() async throws {
        // given / when
        let mounted = await shell(size: CGSize(width: 1000, height: 620), empty: true)
        defer { close(mounted) }

        // then
        #expect(activeDot(mounted.window) == nil)
    }

    @Test func givenARegularWindowWithAShortSentence_whenMounted_thenThereIsNoDot() async throws {
        // given / when
        let mounted = await shell(size: CGSize(width: 1280, height: 800))
        defer { close(mounted) }

        // then — the sentence fits whole, so it is drawn and no dot stands in for it
        #expect(activeDot(mounted.window) == nil)
        #expect(elementCount(mounted.window, Self.sentence) == 1, "\(accessibilityTexts(mounted.window).filter { $0.text == Self.sentence })")
    }
}
