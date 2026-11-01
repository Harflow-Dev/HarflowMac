import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct WorkflowActivityNativeScrollOwnerTests {
    @Test func givenIdenticalPresentationUpdate_whenMounted_thenOwnerSkipsRootAssignmentsAndMeasurements() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 12)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && owner.host != nil }
        let roots = owner.rootAssignmentCount
        let measurements = owner.measurementCount
        let publications = owner.followPublicationCount

        model.refresh += 1
        var stable = 0
        await waitUntil(timeout: 3) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let unchanged = owner.rootAssignmentCount == roots && owner.measurementCount == measurements
                && owner.followPublicationCount == publications
            stable = unchanged ? stable + 1 : 0
            return stable >= 2
        }

        try #require(stable >= 2)
        #expect(owner.rootAssignmentCount == roots)
        #expect(owner.measurementCount == measurements)
        #expect(owner.followPublicationCount == publications)
    }

    @Test func givenSupportedEnvironmentChanges_whenMounted_thenHostedRootIsRefreshedAndRemeasured() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 12)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && owner.host != nil }
        let roots = owner.rootAssignmentCount
        let measurements = owner.measurementCount

        model.colorScheme = .dark
        await waitUntil(timeout: 5) { owner.rootAssignmentCount > roots && owner.measurementCount > measurements }

        #expect(owner.rootAssignmentCount == roots + 1)
        #expect(owner.measurementCount == measurements + 1)
        #expect(owner.following && bottomGap(scroll) <= 3)
    }

    @Test func givenFollowingQueuedPrompt_whenLocalDisclosureExpands_thenHostedHeightReflowsWithoutReplacingRoot() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 8)
        let prompt = String(repeating: "Expand the queued prompt within its natural native height. ", count: 8)
        model.messages = [WorkMessageBubble(id: "expand-prompt", seq: 1,
            kind: .queued(canCancel: true, note: nil), text: prompt)]
        let fixture = RedesignHost(WorkflowLiveFollowFixture(model: model), size: CGSize(width: 420, height: 450))
        defer { fixture.close() }
        var scroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            scroll = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first
            return scroll?.owner?.positioned == true && scroll.map { bottomGap($0) <= 3 } == true
        }
        let feed = try #require(scroll)
        await fixture.settle { fixture.element("Show more") != nil }
        let owner = try #require(feed.owner)
        let expandButton = try #require(fixture.element("Show more"))
        let initialHeight = try #require(feed.documentView?.bounds.height)
        let roots = owner.rootAssignmentCount
        let measurements = owner.measurementCount

        try #require(fixture.press(expandButton))
        await fixture.settle {
            (feed.documentView?.bounds.height ?? 0) > initialHeight + 30 && bottomGap(feed) <= 3
                && owner.measurementCount > measurements
        }

        #expect((feed.documentView?.bounds.height ?? 0) > initialHeight + 30)
        #expect(owner.rootAssignmentCount == roots)
        #expect(owner.measurementCount > measurements)
        #expect(owner.following && bottomGap(feed) <= 3)
    }

    @Test func givenFollowingNativeActivity_whenWindowWidthChanges_thenWrappingReflowsAndStaysAtBottom() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 12, textLength: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) { scroll.owner?.positioned == true && bottomGap(scroll) <= 3 }
        let initialWidth = scroll.contentView.bounds.width
        let initialHeight = try #require(scroll.documentView?.bounds.height)

        window.setContentSize(CGSize(width: 320, height: 450))
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.width < initialWidth - 50
                && (scroll.documentView?.bounds.height ?? 0) > initialHeight + 20 && bottomGap(scroll) <= 3
        }
        try #require(scroll.contentView.bounds.width < initialWidth - 50
            && (scroll.documentView?.bounds.height ?? 0) > initialHeight + 20 && bottomGap(scroll) <= 3)
    }

    @Test func givenPausedNativeActivity_whenWindowWidthChanges_thenPixelOffsetIsRetained() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20, textLength: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) { scroll.owner?.positioned == true && bottomGap(scroll) <= 3 }
        try sendPageUp(scroll)
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 3) { !owner.following && bottomGap(scroll) > 24 }
        try #require(!owner.following && bottomGap(scroll) > 24,
                     "Page Up must establish a paused reading position before reconciliation is checked")
        let offset = owner.readingOffset
        let initialWidth = scroll.contentView.bounds.width
        let oldHeight = try #require(scroll.documentView?.bounds.height)

        window.setContentSize(CGSize(width: 320, height: 450))
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.width < initialWidth - 50
                && (scroll.documentView?.bounds.height ?? 0) > oldHeight + 20
                && abs(owner.readingOffset - offset) < 4
                && bottomGap(scroll) > 24
        }
        try #require(scroll.contentView.bounds.width < initialWidth - 50
            && (scroll.documentView?.bounds.height ?? 0) > oldHeight + 20
            && abs(owner.readingOffset - offset) < 4
            && bottomGap(scroll) > 24)
    }

    @Test func givenLiveScrollNotifications_whenUserMovesUp_thenOwnerPausesUntilGestureEnds() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        let initialOffset = scroll.documentVisibleRect.minY
        try #require(initialOffset > 24)

        // These documented, object-scoped native notifications attribute the synthetic clip move
        // as a user live-scroll sequence; geometry by itself never supplies intent.
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, initialOffset - 100)))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)

        #expect(!owner.following)
        #expect(owner.readingOffset < initialOffset)
        #expect(owner.isInteracting)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: max(0, (scroll.documentView?.bounds.height ?? 0)
            - scroll.contentView.bounds.height + 10)))
        scroll.reflectScrolledClipView(scroll.contentView)
        NotificationCenter.default.post(name: NSScrollView.didLiveScrollNotification, object: scroll)
        #expect(!owner.following, "Reaching the near-bottom band during the live gesture must stay paused")

        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        await waitUntil(timeout: 5) { owner.following && bottomGap(scroll) <= 3 }
        try #require(owner.following && !owner.isInteracting && bottomGap(scroll) <= 3)
    }

    @Test func givenOwnedInputDispatch_whenBoundsChangeIsAttributed_thenReadingPositionUpdates() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        let initialOffset = scroll.documentVisibleRect.minY
        let target = max(0, initialOffset - 100)

        // Exercise the owned input-dispatch attribution path around a synchronous clip update.
        owner.beginInput(upward: true)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: target))
        scroll.reflectScrolledClipView(scroll.contentView)
        owner.endInput()

        #expect(!owner.following)
        #expect(!owner.pendingInput && !owner.isInteracting)
        #expect(abs(owner.readingOffset - target) <= 1)
        try #require(bottomGap(scroll) > 24)
    }

    @Test func givenOwnedInputAtBottomMakesNoMovement_whenLaterContentGrows_thenAttributionDoesNotLatch() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 8)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        let initialViewport = scroll.contentView.bounds.height
        let initialHeight = try #require(scroll.documentView?.bounds.height)
        try #require(initialHeight > initialViewport && bottomGap(scroll) <= 3,
                     "The no-movement input must begin in a scrollable feed at its live bottom")
        let readingOffset = owner.readingOffset

        owner.beginInput(upward: true)
        owner.endInput()
        #expect(!owner.following && owner.reading.upwardIntent && !owner.pendingInput && !owner.isInteracting)
        #expect(owner.readingOffset == readingOffset)

        model.count = 20
        await waitUntil(timeout: 5) {
            let height = scroll.documentView?.bounds.height ?? 0
            return height > initialHeight + 50
                && height - scroll.contentView.bounds.height > readingOffset + 24
                && abs(owner.readingOffset - readingOffset) < 1 && bottomGap(scroll) > 24
        }
        let grownHeight = try #require(scroll.documentView?.bounds.height)
        try #require(grownHeight > initialHeight + 50
            && grownHeight - scroll.contentView.bounds.height > readingOffset + 24
            && !owner.following && owner.reading.upwardIntent
            && !owner.pendingInput && !owner.isInteracting
            && abs(owner.readingOffset - readingOffset) < 1 && bottomGap(scroll) > 24)
    }

    @Test func givenShrinkClampsPausedFeedAtBottom_whenFocusedEndArrives_thenFollowResumesThroughGrowth() async throws {
        // given
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 0.5 }
        try #require(owner.positioned && bottomGap(scroll) <= 0.5)
        try #require(window.makeFirstResponder(scroll))
        try #require(window.firstResponder === scroll)
        let initialOffset = owner.readingOffset
        let initialHeight = try #require(scroll.documentView?.bounds.height)
        let up = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126
        ))
        window.sendEvent(up)
        try #require(window.firstResponder === scroll && !owner.following && owner.reading.upwardIntent
            && owner.readingOffset < initialOffset && bottomGap(scroll) > 0 && bottomGap(scroll) <= 24)
        model.count = 19
        await waitUntil(timeout: 5) {
            let height = scroll.documentView?.bounds.height ?? initialHeight
            return height < initialHeight - 20 && height > scroll.contentView.bounds.height && bottomGap(scroll) <= 0.5
        }
        let shrunkHeight = try #require(scroll.documentView?.bounds.height)
        try #require(shrunkHeight < initialHeight - 20 && shrunkHeight > scroll.contentView.bounds.height
            && bottomGap(scroll) <= 0.5 && !owner.following && owner.reading.upwardIntent
            && !owner.pendingInput && !owner.isInteracting,
            "Shrinking must clamp the paused reader to the bottom of a still-scrollable feed")

        // when
        try #require(window.firstResponder === scroll)
        let end = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F72B}",
            charactersIgnoringModifiers: "\u{F72B}", isARepeat: false, keyCode: 119
        ))
        window.sendEvent(end)
        await waitUntil(timeout: 5) { owner.following && bottomGap(scroll) <= 0.5 }
        try #require(window.firstResponder === scroll && owner.following && !owner.reading.upwardIntent
            && !owner.pendingInput && !owner.isInteracting && bottomGap(scroll) <= 0.5,
            "Focused End must resume following even when shrinkage already clamped the reader to bottom")

        // then
        model.count = 21
        await waitUntil(timeout: 5) {
            (scroll.documentView?.bounds.height ?? 0) > shrunkHeight + 50 && owner.following && bottomGap(scroll) <= 0.5
        }
        try #require((scroll.documentView?.bounds.height ?? 0) > shrunkHeight + 50
            && owner.following && bottomGap(scroll) <= 0.5)
    }

    @Test func givenOwnedReconciliation_whenWritingScrollPosition_thenBoundsChangeDoesNotBecomeUserIntent() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { !owner.following && bottomGap(scroll) > 24 }
        try #require(!owner.following && bottomGap(scroll) > 24,
                     "Page Up must establish a paused reading position before the reconciliation write is checked")

        let depthRecorder = WorkflowScrollDepthRecorder()
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: nil
        ) { _ in
            MainActor.assumeIsolated { depthRecorder.values.append(owner.programmaticScrollDepth) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        owner.resumeFollowing()
        owner.reconcile()
        await waitUntil(timeout: 3) { owner.following && bottomGap(scroll) <= 3 }

        #expect(depthRecorder.values.contains(where: { $0 > 0 }))
        #expect(owner.following && bottomGap(scroll) <= 3)
    }

    @Test func givenShortWorkflowActivity_whenContentGrowsAndShrinks_thenNaturalDocumentTransitions() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 1)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        await waitUntil(timeout: 5) { scroll.owner?.positioned == true }
        let shortHeight = try #require(scroll.documentView?.bounds.height)
        try #require(shortHeight < scroll.contentView.bounds.height)
        #expect(scroll.documentVisibleRect.minY == 0)

        model.count = 20
        await waitUntil(timeout: 5) {
            (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height && bottomGap(scroll) <= 3
        }
        try #require((scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height && bottomGap(scroll) <= 3)

        model.count = 1
        await waitUntil(timeout: 5) { (scroll.documentView?.bounds.height ?? .infinity) < scroll.contentView.bounds.height }
        try #require((scroll.documentView?.bounds.height ?? .infinity) < scroll.contentView.bounds.height)
        #expect(scroll.documentVisibleRect.minY == 0)
        #expect(scroll.owner?.readingOffset == 0)
    }

    @Test func givenNativeViewDetachesAndReattaches_whenPaused_thenSameOwnerRetainsPixelOffset() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        try sendPageUp(scroll)
        await waitUntil(timeout: 3) { !owner.following && bottomGap(scroll) > 24 }
        try #require(!owner.following && bottomGap(scroll) > 24,
                     "Page Up must establish a paused reading position before detaching the native view")
        let offset = owner.readingOffset
        let root = try #require(owner.host?.rootView)
        let oldGeneration = owner.attachmentGeneration
        let documentHeight = try #require(scroll.documentView?.bounds.height)

        window.contentView = nil
        await waitUntil(timeout: 3) { scroll.window == nil }
        owner.onHostedHeight(documentHeight + 500, revision: root.revision, generation: root.attachmentGeneration)
        #expect(owner.attachmentGeneration > oldGeneration)
        #expect(scroll.documentView?.bounds.height == documentHeight)

        window.contentView = host
        await waitUntil(timeout: 5) { scroll.window === window && owner.positioned }
        try #require(scroll.owner === owner && owner.positioned && !owner.following)
        #expect(abs(owner.readingOffset - offset) < 1)
        #expect(bottomGap(scroll) > 24)
    }

    @Test func givenWorkflowActivityIsRemovedAndRecreated_thenNewOwnerStartsAtLiveBottom() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let oldScroll = try #require(await waitForScroll(in: host))
        let oldOwner = try #require(oldScroll.owner)
        await waitUntil(timeout: 5) { oldOwner.positioned && bottomGap(oldScroll) <= 3 }
        try sendPageUp(oldScroll)
        await waitUntil(timeout: 3) { !oldOwner.following && bottomGap(oldScroll) > 24 }

        model.showActivity = false
        await waitUntil(timeout: 3) { oldScroll.owner == nil }
        try #require(oldScroll.owner == nil)
        model.showActivity = true
        let newScroll = try #require(await waitForScroll(in: host, excluding: oldScroll))
        let newOwner = try #require(newScroll.owner)
        await waitUntil(timeout: 5) { newOwner.positioned && bottomGap(newScroll) <= 3 }

        #expect(newOwner !== oldOwner)
        #expect(newOwner.following)
        let expectedOffset = max(0, (newScroll.documentView?.bounds.height ?? 0) - newScroll.contentView.bounds.height)
        #expect(abs(newOwner.readingOffset - expectedOffset) <= 3)
    }

    @Test func givenZeroWidthAtMount_whenWidthBecomesPositive_thenOwnerInitializesAtBottom() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 12)
        model.fixedWidth = 0
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 3) { scroll.contentView.bounds.width == 0 }
        #expect(!owner.positioned)

        model.fixedWidth = nil
        await waitUntil(timeout: 5) {
            scroll.contentView.bounds.width > 0 && owner.positioned && bottomGap(scroll) <= 3
        }
        try #require(scroll.contentView.bounds.width > 0 && owner.positioned && bottomGap(scroll) <= 3)
    }

    @Test func givenPageUpTargetsComposerEditor_whenNativeScrollReceivesKey_thenFollowIsNotPaused() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 20)
        model.composerEnabled = true
        let host = NSHostingView(rootView: WorkflowLiveFollowFixture(model: model))
        let window = open(host)
        defer { window.contentView = nil; window.close() }
        let scroll = try #require(await waitForScroll(in: host))
        let owner = try #require(scroll.owner)
        await waitUntil(timeout: 5) { owner.positioned && bottomGap(scroll) <= 3 }
        var composerField: NSTextField?
        await waitUntil(timeout: 5) {
            composerField = activityNativeDescendants(host)
.compactMap { $0 as? NSTextField }
                .first { $0.placeholderString == "Write a message" }
            return composerField != nil
        }
        let field = try #require(composerField)
        try #require(window.makeFirstResponder(field))
        let editor = try #require(window.firstResponder as? NSTextView)
        try #require(editor.isFieldEditor, "The composer must own AppKit's active field editor")
        let event = try pageUpEvent(in: window)

        window.sendEvent(event)

        #expect(window.firstResponder === editor)
        #expect(owner.following)
        #expect(!owner.pendingInput)
        #expect(bottomGap(scroll) <= 3)
    }

    @Test func givenCancelCallbackChanges_whenPresentationIsEqual_thenHostedButtonUsesLatestAction() async throws {
        let model = WorkflowLiveFollowFixtureModel(count: 8)
        model.messages = [WorkMessageBubble(id: "callback-queue", seq: 1,
            kind: .queued(canCancel: true, note: nil), text: "Cancel this queued message")]
        let fixture = RedesignHost(WorkflowLiveFollowFixture(model: model), size: CGSize(width: 420, height: 450))
        defer { fixture.close() }
        var scroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            scroll = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first
            return scroll?.owner?.positioned == true && scroll.map { bottomGap($0) <= 3 } == true
        }
        let feed = try #require(scroll)
        let owner = try #require(feed.owner)
        let roots = owner.rootAssignmentCount
        let measurements = owner.measurementCount
        model.callbackVersion = 7
        await fixture.settle {
            owner.rootAssignmentCount == roots && owner.measurementCount == measurements
                && fixture.descendants.flatMap(fixture.elements(in:)).contains {
                    fixture.matches($0, "Cancel queued message")
                }
        }
        let cancelButton = try #require(fixture.descendants.flatMap(fixture.elements(in:)).first {
            fixture.matches($0, "Cancel queued message") && fixture.string($0, "accessibilityRole") == "AXButton"
        })

        try #require(fixture.press(cancelButton))

        #expect(model.cancelledMessageID == "callback-queue")
        #expect(model.cancelCallbackVersion == 7)
        #expect(owner.rootAssignmentCount == roots)
        #expect(owner.measurementCount == measurements)
    }

    @Test func givenPageUpEventFromAnotherWindow_whenDeliveredToThisFeed_thenOwnerIgnoresIt() async throws {
        let firstModel = WorkflowLiveFollowFixtureModel(count: 20)
        let secondModel = WorkflowLiveFollowFixtureModel(count: 20)
        let firstHost = NSHostingView(rootView: WorkflowLiveFollowFixture(model: firstModel))
        let secondHost = NSHostingView(rootView: WorkflowLiveFollowFixture(model: secondModel))
        let firstWindow = open(firstHost)
        let secondWindow = open(secondHost)
        defer {
            firstWindow.contentView = nil; firstWindow.close()
            secondWindow.contentView = nil; secondWindow.close()
        }
        let firstScroll = try #require(await waitForScroll(in: firstHost))
        let secondScroll = try #require(await waitForScroll(in: secondHost))
        let firstOwner = try #require(firstScroll.owner)
        let secondOwner = try #require(secondScroll.owner)
        await waitUntil(timeout: 5) {
            firstOwner.positioned && secondOwner.positioned
                && bottomGap(firstScroll) <= 3 && bottomGap(secondScroll) <= 3
        }
        try #require(firstWindow.makeFirstResponder(firstScroll))
        try #require(firstWindow.firstResponder === firstScroll,
                     "The positive control must own focus before another feed receives the event")
        let event = try pageUpEvent(in: firstWindow)

        // Deliver this first-window event to the wrong feed to verify its strict window check.
        secondScroll.keyDown(with: event)

        #expect(firstOwner.following)
        #expect(secondOwner.following)
        #expect(!secondOwner.pendingInput && !secondOwner.isInteracting)
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
        let offsetBeforePageUp = try #require(scroll.owner?.readingOffset)
        window.sendEvent(try pageUpEvent(in: window))
        try #require(window.firstResponder === scroll)
        try #require(scroll.owner?.following == false && (scroll.owner?.readingOffset ?? .infinity) < offsetBeforePageUp,
                     "A focused feed must handle Page Up through the window responder chain")
    }

    private func pageUpEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F72C}",
            charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116
        ))
    }
}

@MainActor private final class WorkflowScrollDepthRecorder {
    var values: [Int] = []
}
