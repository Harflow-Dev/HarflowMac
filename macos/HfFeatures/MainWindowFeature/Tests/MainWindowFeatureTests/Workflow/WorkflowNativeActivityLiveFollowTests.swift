import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowNativeActivityLiveFollowTests {
    @Test func givenFollowingNativeActivity_whenSameExecutionGrows_thenViewportRemainsAtBottom() async throws {
        // given — include the workflow composer in the same mounted activity container.
        let model = WorkflowLiveFollowFixtureModel()
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            let document = scroll.documentView
            return document.map { $0.bounds.height > scroll.contentView.bounds.height } == true
                && bottomGap(scroll) <= 3
        }
        let initialHeight = try #require(scroll.documentView?.bounds.height)
        try #require(initialHeight > scroll.contentView.bounds.height && bottomGap(scroll) <= 3)

        // when — append content while the mounted execution identity remains unchanged.
        model.count = 20

        // then — wait for committed content geometry and live-follow to settle at the new end.
        await waitUntil(timeout: 5) {
            guard let document = scroll.documentView else { return false }
            return document.bounds.height > initialHeight + 50 && bottomGap(scroll) <= 3
        }
        let appendedHeight = try #require(scroll.documentView?.bounds.height)
        try #require(appendedHeight > initialHeight + 50 && bottomGap(scroll) <= 3)
    }

    @Test func givenFollowingNativeActivity_whenWindowHeightShrinksAndGrows_thenFeedRemainsAtBottom() async throws {
        // given — enough activity to keep the document scrollable before and after resizing.
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height }
                == true && bottomGap(scroll) <= 3
        }
        let initialViewportHeight = scroll.contentView.bounds.height

        // when — the window height shrinks, reducing the activity viewport.
        window.setContentSize(CGSize(width: 420, height: 340))

        // then — the content remains pinned to the bottom of the resized viewport.
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.height < initialViewportHeight - 50 && bottomGap(scroll) <= 3
        }
        let reducedHeight = scroll.contentView.bounds.height
        let reducedGap = bottomGap(scroll)
        try #require(
            reducedHeight < initialViewportHeight - 50 && reducedGap <= 3,
            "Resize: viewport=\(reducedHeight), document=\(scroll.documentView?.bounds ?? .zero), gap=\(reducedGap)"
        )

        window.setContentSize(CGSize(width: 420, height: 520))
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.height > initialViewportHeight + 50 && bottomGap(scroll) <= 3
        }
        try #require(scroll.contentView.bounds.height > initialViewportHeight + 50 && bottomGap(scroll) <= 3)
    }

    @Test func givenPausedFollow_whenWindowHeightShrinks_thenReadingAnchorStaysPut() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height }
                == true && bottomGap(scroll) <= 3
        }
        let originalViewport = scroll.contentView.bounds.height

        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { bottomGap(scroll) > 24 }
        try #require(bottomGap(scroll) > 24)
        let readingOffset = scroll.documentVisibleRect.minY
        let documentHeight = try #require(scroll.documentView?.bounds.height)

        window.setContentSize(CGSize(width: 420, height: 340))
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.height < originalViewport - 50
                && (scroll.documentView?.bounds.height ?? 0) == documentHeight
                && bottomGap(scroll) > 24
                && abs(scroll.documentVisibleRect.minY - readingOffset) < 4
        }
        try #require(
            scroll.contentView.bounds.height < originalViewport - 50
                && (scroll.documentView?.bounds.height ?? 0) == documentHeight
                && bottomGap(scroll) > 24
                && abs(scroll.documentVisibleRect.minY - readingOffset) < 4,
            "Paused resize: viewport=\(scroll.contentView.bounds.height), offset=\(scroll.documentVisibleRect.minY), gap=\(bottomGap(scroll))"
        )
    }

    @Test func givenPausedFollow_whenSameIDTextGrowsAndRowsAppend_thenReadingOffsetStaysPut() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 12)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height }
                == true && bottomGap(scroll) <= 3
        }

        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { bottomGap(scroll) > 24 }
        try #require(bottomGap(scroll) > 24)
        let readingOffset = scroll.documentVisibleRect.minY
        let initialHeight = try #require(scroll.documentView?.bounds.height)
        model.textLength = 30
        await waitUntil(timeout: 5) {
            (scroll.documentView?.bounds.height ?? 0) > initialHeight + 50
                && abs(scroll.documentVisibleRect.minY - readingOffset) < 4 && bottomGap(scroll) > 24
        }
        let editedHeight = try #require(scroll.documentView?.bounds.height)
        try #require(editedHeight > initialHeight + 50
            && abs(scroll.documentVisibleRect.minY - readingOffset) < 4 && bottomGap(scroll) > 24)

        model.count = 20
        await waitUntil(timeout: 5) {
            (scroll.documentView?.bounds.height ?? 0) > editedHeight + 50
                && abs(scroll.documentVisibleRect.minY - readingOffset) < 4 && bottomGap(scroll) > 24
        }
        let appendedHeight = try #require(scroll.documentView?.bounds.height)
        try #require(appendedHeight > editedHeight + 50
            && abs(scroll.documentVisibleRect.minY - readingOffset) < 4 && bottomGap(scroll) > 24)
    }

    @Test func givenPausedExecution_whenExecutionIdentityChanges_thenNewExecutionStartsFollowing() async throws {
        // Use the production caller so this exercises WorkflowSelectedSidebar's real .id boundary.
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        vm.nativeActivity = activity(executionID: "first-execution", count: 20)
        let host = NSHostingView(rootView: WorkflowSelectedSidebar(viewModel: vm)
            .frame(width: 420, height: 450))
        let window = open(host)
        defer { vm.didDisappear(); window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height }
                == true && bottomGap(scroll) <= 3
        }

        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { bottomGap(scroll) > 24 }
        try #require(bottomGap(scroll) > 24)
        let previousHeight = try #require(scroll.documentView?.bounds.height)
        vm.nativeActivity = activity(executionID: "replacement-execution", count: 24)

        let replacementScroll = try #require(await waitForScroll(in: host, excluding: scroll))
        await waitUntil(timeout: 5) {
            guard replacementScroll !== scroll, let document = replacementScroll.documentView else { return false }
            return document.bounds.height > previousHeight + 50 && bottomGap(replacementScroll) <= 3
        }
        let replacementHeight = try #require(replacementScroll.documentView?.bounds.height)
        try #require(replacementScroll !== scroll && replacementHeight > previousHeight + 50
            && bottomGap(replacementScroll) <= 3)
    }

    @Test func givenPausedFollow_whenRowsShrink_thenReadingOffsetStaysPut() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) {
            scroll.documentView.map { $0.bounds.height > scroll.contentView.bounds.height }
                == true && bottomGap(scroll) <= 3
        }

        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { bottomGap(scroll) > 24 }
        try #require(bottomGap(scroll) > 24)
        let readingOffset = scroll.documentVisibleRect.minY
        let oldHeight = try #require(scroll.documentView?.bounds.height)
        model.count = 18

        await waitUntil(timeout: 5) {
            let height = scroll.documentView?.bounds.height ?? oldHeight
            let maximumOffset = height - scroll.contentView.bounds.height
            return height < oldHeight - 20 && maximumOffset > readingOffset + 24
        }
        let shrunkHeight = try #require(scroll.documentView?.bounds.height)
        let shrunkMaximumOffset = shrunkHeight - scroll.contentView.bounds.height
        try #require(
            shrunkHeight < oldHeight - 20 && shrunkMaximumOffset > readingOffset + 24,
            """
            Shrink fixture must leave the saved offset reachable: saved=\(readingOffset), maximum=\(shrunkMaximumOffset),
            viewport=\(scroll.contentView.bounds.height)
            """
        )
        await waitUntil(timeout: 5) {
            abs(scroll.documentVisibleRect.minY - readingOffset) < 4 && bottomGap(scroll) > 24
        }
        try #require(bottomGap(scroll) > 24
            && abs(scroll.documentVisibleRect.minY - readingOffset) < 4)
    }

    @Test func givenPausedFollow_whenQueuedJumpIsSelected_thenLiveBottomResumes() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let fixture = RedesignHost(WorkflowLiveFollowFixture(model: model), size: CGSize(width: 420, height: 450))
        defer { fixture.close() }
        var scroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            scroll = fixture.descendants
                .compactMap { $0 as? WorkflowActivityNativeScrollView }
                .first { $0.identifier?.rawValue == "workflow-native-activity" && $0.documentView != nil }
            return scroll != nil
        }
        let feed = try #require(scroll)
        await fixture.settle {
            feed.documentView.map { $0.bounds.height > feed.contentView.bounds.height } == true
                && bottomGap(feed) <= 3
        }
        try #require(bottomGap(feed) <= 3)
        try sendPageUp(feed)
        await fixture.settle { bottomGap(feed) > 24 }
        try #require(bottomGap(feed) > 24)
        let previousHeight = try #require(feed.documentView?.bounds.height)

        model.messages = [WorkMessageBubble(id: "queued-fixture", seq: 1,
            kind: .queued(canCancel: true, note: nil), text: "Queued follow-up")]
        func queuedJumpButton() -> NSObject? {
            fixture.descendants.flatMap(fixture.elements(in:)).first { element in
                fixture.matches(element, "Queued message") && fixture.string(element, "accessibilityRole") == "AXButton"
            }
        }
        await fixture.settle {
            guard let document = feed.documentView else { return false }
            return document.bounds.height > previousHeight + 20 && queuedJumpButton() != nil
        }
        let jumpButton = try #require(
            queuedJumpButton(),
            "Queued-message button must be exposed in the mounted production workflow view"
        )
        try #require((feed.documentView?.bounds.height ?? 0) > previousHeight + 20)
        try #require(fixture.press(jumpButton), "the queued-message jump must expose a press action")

        await fixture.settle { bottomGap(feed) <= 3 }
        try #require(bottomGap(feed) <= 3)
    }

    private func open(_ host: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return window
    }

    private func waitForScroll(in host: NSView, excluding excluded: WorkflowActivityNativeScrollView? = nil) async -> WorkflowActivityNativeScrollView? {
        var result: WorkflowActivityNativeScrollView?
        await waitUntil(timeout: 5) {
            result = activityNativeDescendants(host).compactMap { $0 as? WorkflowActivityNativeScrollView }.first {
                $0 !== excluded && $0.window != nil && $0.hasVerticalScroller && $0.documentView != nil
            }
            return result != nil
        }
        return result
    }

    private func bottomGap(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .greatestFiniteMagnitude }
        return abs(document.bounds.maxY - scroll.documentVisibleRect.maxY)
    }

    private func sendPageUp(_ scroll: WorkflowActivityNativeScrollView) throws {
        let window = try #require(scroll.window)
        try #require(window.makeFirstResponder(scroll))
        try #require(window.firstResponder === scroll,
                     "Page Up requires the activity feed to be the actual window first responder")
        let owner = try #require(scroll.owner)
        let offsetBeforePageUp = owner.readingOffset
        window.sendEvent(try pageUpEvent(in: window))
        try #require(window.firstResponder === scroll)
        try #require(!owner.following && owner.readingOffset < offsetBeforePageUp,
                     "A focused feed must handle Page Up through the window responder chain")
    }

    private func pageUpEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F72C}",
            charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116
        ))
    }

    private func activity(executionID: String, count: Int) -> WorkflowNativeActivityModel {
        let items = (0 ..< count).map {
            PreviewFixtures.textItem("Activity row \($0): " + String(repeating: "Output grows. ", count: 8), seq: $0)
        }
        return WorkflowNativeActivityModel(executionID: executionID, title: "Review", status: "running",
                                           limited: false, items: items)
    }
}

@MainActor final class WorkflowLiveFollowFixtureModel: ObservableObject {
    @Published var count: Int
    @Published var textLength = 8
    @Published var executionID = "workflow-live-follow-fixture"
    @Published var messages: [WorkMessageBubble] = []
    @Published var showActivity = true
    @Published var fixedWidth: CGFloat?
    @Published var composerEnabled = false
    @Published var refresh = 0
    @Published var callbackVersion = 0
    @Published var cancelledMessageID: String?
    @Published var cancelCallbackVersion: Int?
    @Published var colorScheme: ColorScheme = .light

    init(count: Int = 12, textLength: Int = 8) {
        self.count = count
        self.textLength = textLength
    }

    var activity: WorkflowNativeActivityModel {
        let items = (0 ..< count).map {
            PreviewFixtures.textItem("Activity row \($0): " + String(repeating: "Output grows. ", count: textLength), seq: $0)
        }
        return WorkflowNativeActivityModel(executionID: executionID, title: "Review", status: "running",
                                           limited: false, items: items)
    }
}

@MainActor struct WorkflowLiveFollowFixture: View {
    @ObservedObject var model: WorkflowLiveFollowFixtureModel

    var body: some View {
        VStack(spacing: 0) {
            if model.showActivity {
                let callbackVersion = model.callbackVersion
                WorkflowNativeActivityView(model: model.activity, messages: model.messages, onCancel: { id in
                    model.cancelledMessageID = id
                    model.cancelCallbackVersion = callbackVersion
                })
                    .id(model.executionID)
            }
            MessageBoxView(model: model.composerEnabled ? MessageBoxModel(
                canSend: true, canContinue: false, isBusy: false, label: "Messages",
                hint: "", placeholder: "Write a message", buttonLabel: "Send"
            ) : .disabled) { _ in true }
        }
        .background(Text("\(model.refresh)").hidden())
        .environment(\.colorScheme, model.colorScheme)
        .frame(width: model.fixedWidth)
        .frame(minWidth: model.fixedWidth == nil ? 220 : 0, minHeight: 280)
    }
}
