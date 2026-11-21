import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowNativeActivityLiveFollowTests {
    @Test func givenPinnedQueueAndTimeline_whenMounted_thenQueuedBubbleIsLastInsideTheActivityDocument() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 8)
        model.messages = [WorkMessageBubble(id: "workflow-queued-last", seq: 1,
            kind: .queued(canCancel: true, note: nil), text: "Queued follow-up inside the task content")]
        let fixture = RedesignHost(WorkflowLiveFollowFixture(model: model), size: CGSize(width: 420, height: 450))
        defer { fixture.close() }
        var scroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            scroll = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first
            return scroll?.owner?.positioned == true && scroll.map { bottomGap($0) <= 3 } == true
        }

        let feed = try #require(scroll)
        let document = try #require(feed.documentView)
        let marker = try #require(fixture.elements(in: document).first {
            fixture.string($0, "accessibilityLabel")?.contains("Queued follow-up inside the task content") == true
                || fixture.string($0, "accessibilityValue")?.contains("Queued follow-up inside the task content") == true
        })
        let lastTimeline = try #require(fixture.elements(in: document).first {
            fixture.string($0, "accessibilityLabel")?.contains("Activity row 7:") == true
                || fixture.string($0, "accessibilityValue")?.contains("Activity row 7:") == true
        })
        let queuedFrame = try #require(fixture.frame(marker))
        let timelineFrame = try #require(fixture.frame(lastTimeline))
        let queuedDocumentFrame = document.convert(queuedFrame, from: nil)
        let timelineDocumentFrame = document.convert(timelineFrame, from: nil)
        let documentFrame = document.convert(document.bounds, to: nil)
        let viewportFrame = feed.contentView.convert(feed.contentView.bounds, to: nil)
        #expect(documentFrame.insetBy(dx: -1, dy: -1).contains(queuedFrame), "The queued bubble belongs to the activity document")
        #expect(document.isFlipped ? queuedDocumentFrame.minY > timelineDocumentFrame.maxY
            : queuedDocumentFrame.maxY < timelineDocumentFrame.minY,
                "The queued bubble follows the newest timeline row")
        let gap = bottomGap(feed)
        #expect(viewportFrame.intersects(queuedFrame) && gap <= 3,
                "viewport=\(viewportFrame), queued=\(queuedFrame), gap=\(gap)")
    }

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

    @Test func givenNativeCallSelectors_whenPointerThenKeyboardSelectAcrossExecutionRemounts_thenRevealAndFocusFollowInputModality() async throws {
        let previousActivationPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        model.callRows = [
            WorkflowOnDemandCallRow(id: "call-one", number: 1, status: "succeeded", startedAt: 1000, finishedAt: 1010, taskID: nil),
            WorkflowOnDemandCallRow(id: "call-two", number: 2, status: "succeeded", startedAt: 1020, finishedAt: 1030, taskID: nil)
        ]
        model.selectedCallID = "call-two"
        let fixture = RedesignHost(WorkflowLiveFollowFixture(model: model), size: CGSize(width: 420, height: 320))
        defer { fixture.close() }
        try await resourceInteractionForeground(fixture)

        var initialScroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            initialScroll = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first
            return initialScroll?.owner?.positioned == true
        }
        let firstFeed = try #require(initialScroll)
        let callOneFeed = try await selectNativeCallByPointer("call-one", from: firstFeed, model: model, fixture: fixture)
        let callTwoFeed = try await selectNativeCallByKeyboard("call-two", from: callOneFeed, model: model, fixture: fixture)
        #expect(callTwoFeed !== callOneFeed)
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

    private func nativeCallSelector(_ identifier: String, in fixture: RedesignHost) throws -> NSButton {
        let buttons = fixture.descendants.compactMap { $0 as? NSButton }
        return try #require(buttons.first { $0.accessibilityIdentifier() == identifier })
    }

    private func selectNativeCallByPointer(
        _ activationID: String,
        from oldFeed: WorkflowActivityNativeScrollView,
        model: WorkflowLiveFollowFixtureModel,
        fixture: RedesignHost
    ) async throws -> WorkflowActivityNativeScrollView {
        let identifier = "workflow-call-selector-\(activationID)"
        let frame = try await revealCallSelector(identifier, in: oldFeed, fixture: fixture)
        try clickCallSelector(identifier, frame: frame, fixture: fixture)
        var newFeed: WorkflowActivityNativeScrollView?
        await fixture.settle {
            newFeed = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first { $0 !== oldFeed }
            return model.selectedCallID == activationID && newFeed?.owner?.positioned == true
        }
        let feed = try #require(newFeed)
        let revealed = try await visibleCallSelector(identifier, in: feed, fixture: fixture)
        let revealToken = try #require(model.callRevealTokens[activationID])
        await fixture.settle { model.callScrollAcknowledgements.contains(revealToken) }
        try #require(model.callScrollAcknowledgements.contains(revealToken),
                     "Pointer selection acknowledges scrolling to the exact selector token")
        try #require(feed.contentView
.convert(feed.contentView.bounds, to: nil)
.insetBy(dx: -1, dy: -1)
            .contains(revealed), "Pointer selection keeps the exact selector visible")
        #expect(fixture.window.firstResponder !== (try nativeCallSelector(identifier, in: fixture)),
                "Pointer selection does not programmatically focus the remounted native selector")
        return feed
    }

    private func selectNativeCallByKeyboard(
        _ activationID: String,
        from oldFeed: WorkflowActivityNativeScrollView,
        model: WorkflowLiveFollowFixtureModel,
        fixture: RedesignHost
    ) async throws -> WorkflowActivityNativeScrollView {
        let identifier = "workflow-call-selector-\(activationID)"
        _ = try await revealCallSelector(identifier, in: oldFeed, fixture: fixture)
        let oldButton = try nativeCallSelector(identifier, in: fixture)
        try #require(fixture.window.makeFirstResponder(oldButton))
        try sendSpaceKey(in: fixture.window)
        await fixture.settle { model.selectedCallID == activationID }

        var newFeed: WorkflowActivityNativeScrollView?
        await fixture.settle {
            newFeed = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first { $0 !== oldFeed }
            return newFeed?.owner?.positioned == true
        }
        let feed = try #require(newFeed)
        let revealed = try await visibleCallSelector(identifier, in: feed, fixture: fixture)
        let revealToken = try #require(model.callRevealTokens[activationID])
        await fixture.settle { model.callScrollAcknowledgements.contains(revealToken) }
        try #require(model.callScrollAcknowledgements.contains(revealToken),
                     "Keyboard selection acknowledges scrolling to the exact selector token")
        try #require(feed.contentView
.convert(feed.contentView.bounds, to: nil)
.insetBy(dx: -1, dy: -1)
            .contains(revealed), "Keyboard selection keeps the exact selector visible")
        let newButton = try nativeCallSelector(identifier, in: fixture)
        await fixture.settle { fixture.window.firstResponder === newButton }
        try #require(fixture.window.firstResponder === newButton,
                     "Keyboard selection restores focus to the exact selector in the remounted execution")
        return feed
    }

    private func revealCallSelector(_ identifier: String, in scroll: WorkflowActivityNativeScrollView,
                                    fixture: RedesignHost) async throws -> CGRect {
        if let owner = scroll.owner, owner.following { try sendPageUp(scroll) }
        var frame = CGRect.zero
        var viewport = CGRect.zero
        for _ in 0 ..< 4 {
            let button = try nativeCallSelector(identifier, in: fixture)
            frame = try #require(fixture.frame(button))
            viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            if viewport.insetBy(dx: -1, dy: -1).contains(frame) { return frame }
            guard let document = scroll.documentView else { break }
            document.scrollToVisible(document.convert(frame, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
            await fixture.settle {
                guard let currentButton = try? nativeCallSelector(identifier, in: fixture),
                      let currentFrame = fixture.frame(currentButton) else { return false }
                frame = currentFrame
                viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
                return viewport.insetBy(dx: -1, dy: -1).contains(currentFrame)
            }
        }
        try #require(viewport.insetBy(dx: -1, dy: -1).contains(frame),
                     Comment(rawValue: "Could not reveal \(identifier): frame=\(frame), viewport=\(viewport)"))
        return frame
    }

    private func visibleCallSelector(_ identifier: String, in scroll: WorkflowActivityNativeScrollView,
                                     fixture: RedesignHost) async throws -> CGRect {
        var frame = CGRect.zero
        var viewport = CGRect.zero
        await fixture.settle {
            guard let button = try? nativeCallSelector(identifier, in: fixture),
                  let currentFrame = fixture.frame(button) else { return false }
            frame = currentFrame
            viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            return viewport.insetBy(dx: -1, dy: -1).contains(currentFrame)
        }
        try #require(viewport.insetBy(dx: -1, dy: -1).contains(frame),
                     Comment(rawValue: "Remounted selector is not visible: \(identifier), frame=\(frame), viewport=\(viewport)"))
        return frame
    }

    private func clickCallSelector(_ identifier: String, frame: CGRect, fixture: RedesignHost) throws {
        let button = try nativeCallSelector(identifier, in: fixture)
        let nativeFrame = button.convert(button.bounds, to: nil)
        try #require(nativeFrame.insetBy(dx: -1, dy: -1).contains(CGPoint(x: frame.midX, y: frame.midY)))
        let point = CGPoint(x: frame.midX, y: frame.midY)
        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(mouseUp, atStart: false)
        fixture.window.sendEvent(mouseDown)
    }

    private func sendSpaceKey(in window: NSWindow) throws {
        let keyDown = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        let keyUp = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: 49
        ))
        NSApp.postEvent(keyDown, atStart: true)
        NSApp.postEvent(keyUp, atStart: false)
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
    @Published var callRows: [WorkflowOnDemandCallRow] = []
    @Published var selectedCallID: String?
    @Published var callReveal: WorkflowInspectorCallReveal?
    private(set) var callRevealTokens: [String: UUID] = [:]
    private(set) var callScrollAcknowledgements: Set<UUID> = []

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

    var callSelectorRows: [ActivityFeedSupplementaryRow] {
        callRows.map { row in
            let rowID = "workflow-inspector-live-follow-callSelector-\(row.id)"
            let reveal = callReveal?.rowID == rowID ? callReveal : nil
            let focusToken = reveal?.takesFocus == true ? reveal?.token : nil
            let selected = selectedCallID == row.id
            let content = AnyView(WorkflowInspectorCallSelector(row: row, selected: selected, focusToken: focusToken,
                onSelect: { self.selectCall(rowID: rowID, activationID: row.id) }, onOpenTask: { _ in },
                onFocusAcknowledged: { self.acknowledgeCallFocus($0) }))
            return ActivityFeedSupplementaryRow(scope: "live-follow", kind: .callSelector,
                input: .call(row, selected: selected, focusToken: focusToken), content: content, key: row.id)
        }
    }

    private func selectCall(rowID: String, activationID: String) {
        let eventType = NSApp.currentEvent?.type
        let takesFocus = eventType == .keyDown || eventType == .keyUp
        let token = UUID()
        callRevealTokens[activationID] = token
        callReveal = WorkflowInspectorCallReveal(rowID: rowID, token: token, takesFocus: takesFocus,
                                                  activationID: activationID)
        selectedCallID = activationID
        executionID = "workflow-live-follow-\(activationID)"
    }

    func acknowledgeCallScroll(_ token: UUID) {
        callScrollAcknowledgements.insert(token)
        guard callReveal?.token == token, callReveal?.takesFocus == false else { return }
        callReveal = nil
    }

    private func acknowledgeCallFocus(_ token: UUID) {
        guard callReveal?.token == token, callReveal?.takesFocus == true else { return }
        callReveal = nil
    }
}
