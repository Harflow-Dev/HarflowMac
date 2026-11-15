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
        let viewModel: ParallelGroupTopBarHostedTests.GroupScreenVM
    }

    private func shell(size: CGSize, empty: Bool = false, members: Int = 2, collapsed: Bool = false, dark: Bool? = nil,
                       captioned: Bool = false) async -> Shell {
        _ = NSApplication.shared
        let vm = ParallelGroupTopBarHostedTests.GroupScreenVM()
        vm.isEmpty = empty
        vm.columns = empty ? [] : Self.columns(members, captioned: captioned)
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
        let controller = NSHostingController(rootView: AnyView(MainWindowNavigationView(coordinator, sidebarCollapsed: collapsed)
            .environment(\.hfReduceMotionOverride, true)))
        controller.sceneBridgingOptions = .all
        let window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: size.width, height: size.height))
        if let dark { window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua) }
        var passes = 0
        await waitUntil(timeout: 10) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            passes += 1
            return passes >= 120
        }
        return Shell(window: window, writer: writer, viewModel: vm)
    }

    /// `count` resident-looking lanes with distinct ids and titles. A captioned set carries a model label on the first lane
    /// and a bare harness on the second, the design's two caption shapes.
    private static func columns(_ count: Int, captioned: Bool) -> [ParallelColumnModel] {
        (0 ..< count).map { index in
            let task = TaskInfo(.object([
                "task_id": .string("lane\(index)"), "backend": .string(index == 1 ? "codex" : "claude"),
                "status": .string(index == 0 ? "running" : "completed"),
                "started_at": .string(ISO8601DateFormatter().string(from: .now.addingTimeInterval(-90)))
            ]))!
            var model = ParallelColumnModel(
                id: "lane\(index)", task: task, title: "Lane \(index) task", subtitle: "repo", isBusy: false, outcomeMessage: nil,
                showPrompt: false, rows: [], activityRows: [], liveStep: nil, isLoading: false, summary: nil, stepCountText: nil,
                noToolCallsText: nil, onTapTakeover: {}, onTapOpenTask: {})
            if captioned { model.caption = index == 1 ? "Codex" : "Claude · Opus 5.5" }
            return model
        }
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

    /// The screen frame of the first element labelled or valued `text` that reports a non-empty one.
    private func frameOfText(_ text: String, in window: NSWindow) -> CGRect? {
        var seen = Set<ObjectIdentifier>()
        var queue: [NSObject] = [window.contentView].compactMap(\.self)
        while let next = queue.popLast(), seen.count < 30000 {
            guard seen.insert(ObjectIdentifier(next)).inserted else { continue }
            let carriesText = ["accessibilityLabel", "accessibilityValue"].contains { key in
                let selector = NSSelectorFromString(key)
                return next.responds(to: selector) && next.perform(selector)?.takeUnretainedValue() as? String == text
            }
            if carriesText {
                if let accessible = next as? NSAccessibilityProtocol, accessible.accessibilityFrame() != .zero { return accessible.accessibilityFrame() }
                if next.responds(to: NSSelectorFromString("accessibilityFrame")),
                   let value = next.value(forKey: "accessibilityFrame") as? NSValue, value.rectValue != .zero { return value.rectValue }
            }
            let children = NSSelectorFromString("accessibilityChildren")
            if next.responds(to: children), let kids = next.perform(children)?.takeUnretainedValue() as? [NSObject] { queue.append(contentsOf: kids) }
            if let view = next as? NSView { queue.append(contentsOf: view.subviews) }
        }
        return nil
    }

    /// The horizontal lane row's scroll view.
    private func laneScroll(_ window: NSWindow) throws -> NSScrollView {
        let content = try #require(window.contentView)
        return try #require(views(content).compactMap { $0 as? NSScrollView }.first {
            $0.hasHorizontalScroller && ($0.documentView?.frame.height ?? 0) > 300
        })
    }

    /// The lane viewport: the clip view inside the scroll view's leading content inset.
    private func viewport(_ scroll: NSScrollView) -> CGFloat { scroll.contentView.bounds.width - scroll.contentInsets.left }

    /// The row's logical offset: 0 is lane 1 at the leading inset.
    private func logicalOffset(_ scroll: NSScrollView) -> CGFloat { scroll.documentVisibleRect.minX + scroll.contentInsets.left }

    @Test func givenTheMinimumWindow_whenMounted_thenTwoWholeLanesAndAFourteenPointPeekOfTheThirdShowAndTheTitleIsWhole() async throws {
        // given / when
        let mounted = await shell(size: CGSize(width: 1000, height: 620), members: 3)
        defer { close(mounted) }

        // then — the lane viewport is the design's 736 pt detail column (the floating sidebar's 8 pt margin is taken back):
        // two whole 361 pt lanes plus a 14 pt peek
        let scroll = try laneScroll(mounted.window)
        let viewport = viewport(scroll)
        let peek = viewport - 2 * (ParallelLayout.minimumColumnWidth + ParallelLayout.dividerWidth)
        #expect(abs(scroll.contentInsets.left - 264) <= 0.5, "the content inset is the 264 pt column edge: \(scroll.contentInsets)")
        #expect(abs(viewport - 736) <= 0.5, "lane viewport in the real shell: \(viewport)")
        #expect(peek > 0, "the third lane intersects the viewport, so it is resident: peek \(peek)")
        #expect(abs(peek - 14) <= 1, "measured peek in the real shell: \(peek)")
        #expect(accessibilityLabels(mounted.window).contains("release"), "the title is whole")
        // the first lane's title starts to the right of the floating sidebar panel's trailing edge (272 pt), not under it
        let first = try #require(frameOfText("Lane 0 task", in: mounted.window), "no lane 1 title")
        #expect(first.minX - mounted.window.frame.minX >= 272 - 0.5, "lane 1 title \(first) is under the sidebar panel")
    }

    @Test(arguments: [1, 2, 3], [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)])
    func givenLaneRowsOfOneTwoAndThreeMembers_whenMounted_thenFittingRowsFillTheViewportAndThreeKeepTheFloor(
        members: Int, size: CGSize
    ) async throws {
        // given / when
        let mounted = await shell(size: size, members: members)
        defer { close(mounted) }

        // then — lanes divide the 264-relative viewport; the last lane of a fitting row ends at the viewport's trailing edge
        let scroll = try laneScroll(mounted.window)
        let viewport = viewport(scroll)
        let document = try #require(scroll.documentView).frame.width
        #expect(abs(viewport - (size.width - 264)) <= 0.5, "viewport \(viewport) at \(size)")
        if members < 3 {
            #expect(abs(document - viewport) <= 0.5, "\(members) lanes fill the viewport: document \(document), viewport \(viewport)")
        } else {
            let floor = ParallelLayout.documentWidth(memberCount: 3, columnWidth: ParallelLayout.minimumColumnWidth, chrome: .lane)
            #expect(abs(document - floor) <= 0.5, "three lanes keep the 360 pt floor: \(document)")
            #expect(document > viewport)
        }
    }

    @Test func givenTheCollapsedSidebar_whenMountedAtTheMinimumWindow_thenTheLaneRowIsUnchanged() async throws {
        // given / when — the rail is a separate 57 pt column outside the split view, so nothing is recovered
        let mounted = await shell(size: CGSize(width: 1000, height: 620), members: 3, collapsed: true)
        defer { close(mounted) }

        // then
        let scroll = try laneScroll(mounted.window)
        #expect(scroll.contentInsets.left == 0, "no inset beside the rail: \(scroll.contentInsets)")
        #expect(abs(viewport(scroll) - (1000 - 57)) <= 0.5, "viewport \(viewport(scroll))")
    }

    /// Whether the row's scroll view carries `inset` and spans the window (after the sidebar's own transition ended).
    private func settledRow(_ window: NSWindow, inset: CGFloat) -> Bool {
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        guard let scroll = try? laneScroll(window) else { return false }
        return abs(scroll.contentInsets.left - inset) <= 0.5
    }

    @Test func givenAScrolledRow_whenTheSidebarCollapsesAndExpandsAgain_thenTheInsetFollowsAndThePositionStaysValid() async throws {
        // given — three lanes, scrolled 100 pt into the row
        let mounted = await shell(size: CGSize(width: 1000, height: 620), members: 3)
        defer { close(mounted) }
        var scroll = try laneScroll(mounted.window)
        let start = CGPoint(x: 100 - scroll.contentInsets.left, y: 0)
        scroll.contentView.scroll(to: start)
        scroll.reflectScrolledClipView(scroll.contentView)
        await settle(mounted.window)
        #expect(abs(logicalOffset(scroll) - 100) <= 1, "scrolled to \(logicalOffset(scroll))")

        // when — collapse through the sidebar's own button
        let collapse = try #require(ShellMatrix.element("Collapse sidebar", in: mounted.window))
        #expect(ShellMatrix.press(collapse))
        await settle(mounted.window, passes: 40)
        await waitUntil(timeout: 5) { settledRow(mounted.window, inset: 0) }

        // then — no inset beside the rail, the position kept (a valid clamp)
        scroll = try laneScroll(mounted.window)
        #expect(scroll.contentInsets.left == 0, "collapsed inset \(scroll.contentInsets)")
        #expect(abs(viewport(scroll) - 943) <= 0.5, "collapsed viewport \(viewport(scroll))")
        #expect(abs(logicalOffset(scroll) - 100) <= 1, "collapsed offset \(logicalOffset(scroll))")

        // when — expand again through the rail
        let expand = try #require(ShellMatrix.element("Expand sidebar", in: mounted.window))
        #expect(ShellMatrix.press(expand))
        await settle(mounted.window, passes: 40)
        await waitUntil(timeout: 5) { settledRow(mounted.window, inset: 264) }

        // then — the recovered 264 pt inset is back and the position is still the reader's, within what the viewport allows
        // (expanding a collapsed sidebar can widen the split view, so the viewport is not asserted against 736 here)
        scroll = try laneScroll(mounted.window)
        #expect(abs(scroll.contentInsets.left - 264) <= 0.5, "expanded inset \(scroll.contentInsets)")
        #expect(scroll.convert(scroll.bounds, to: nil).minX == 0, "the row runs under the sidebar again: \(scroll.convert(scroll.bounds, to: nil))")
        #expect(viewport(scroll) >= 736 - 0.5, "expanded viewport \(viewport(scroll))")
        let document = try #require(scroll.documentView).frame.width
        #expect(abs(logicalOffset(scroll) - min(100, max(0, document - viewport(scroll)))) <= 1, "expanded offset \(logicalOffset(scroll))")
    }

    // MARK: Captures

    /// Opt-in review captures (`HARFLOW_PARALLEL_LANES_CAPTURE_DIR`) of the titled lanes with their captions, light and dark at
    /// both approved sizes. The first lane carries a model label, the second only its harness.
    @Test(arguments: [false, true], [CGSize(width: 1000, height: 620), CGSize(width: 1280, height: 800)])
    func givenTitledLanesWithCaptions_whenTheCaptureDirectoryIsSet_thenTheWindowIsCaptured(dark: Bool, size: CGSize) async throws {
        guard let directory = HostedCaptureEvidence.directory("HARFLOW_PARALLEL_LANES_CAPTURE_DIR") else { return }

        // given
        let mounted = await shell(size: size, members: 3, dark: dark, captioned: true)
        defer { close(mounted) }
        await HostedCaptureEvidence.prepare(mounted.window, dark: dark)

        // then
        #expect(accessibilityLabels(mounted.window).contains("Claude · Opus 5.5"), "the labelled caption is drawn")
        #expect(accessibilityLabels(mounted.window).contains("Codex"), "the model-less harness is drawn alone")
        let minimum = size.width <= 1000
        let host = try #require(mounted.window.contentView)
        let subject = HostedCaptureEvidence.Subject(
            suite: "parallel-lanes", state: minimum ? "lanes-titled-minimum" : "lanes-titled", dark: dark,
            size: NSSize(width: size.width, height: size.height),
            design: .init(route: minimum ? "#parallel-group/lanes-titled-minimum" : "#parallel-group/lanes-titled",
                          file: "v2/scripts/states-parallel-lanes.js", commit: "2153ab1"))
        try await HostedCaptureEvidence.record(directory: directory, subject: subject, window: mounted.window, host: host)
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
