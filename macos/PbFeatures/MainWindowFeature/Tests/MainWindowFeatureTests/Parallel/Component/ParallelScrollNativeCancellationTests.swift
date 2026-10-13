import AppKit
@testable import MainWindowFeature
import PbTestUtilities
import Testing

// MARK: - ParallelScrollNativeIdentityTests cancellation matrix

@MainActor extension ParallelScrollNativeIdentityTests {
    @Test func givenNumericRestorationWithoutAnchorProvider_whenDownwardKnobIntentArrives_thenRepeatedConfigurationCannotRearmStaleTarget() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        harness.targetA.scrollerStyle = .legacy
        harness.targetA.layoutSubtreeIfNeeded()
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var offsets: [CGFloat] = []
        var cancellations: [(generation: Int, isUpward: Bool)] = []
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.usesNativeIdentity = true
        view.followsLive = false
        view.onRestorationCancelled = { context in
            cancellations.append((context.generation, context.isUpward))
            return context.generation
        }
        view.configure(ids: [], stride: 0, restorationOffset: 100, restorationActive: true, generation: 1)
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 100) < 2 } }
        try #require(offsets.contains { abs($0 - 100) < 2 }, "Initial numeric restoration must settle")

        let scroller = try #require(harness.targetA.verticalScroller)
        let knob = scroller.rect(for: .knob)
        try #require(knob.width > 0 && knob.height > 0)
        let windowPoint = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        view.observeNativeNavigationIntent(event)
        try #require(cancellations.count == 1)
        #expect(cancellations[0].generation == 1)
        #expect(!cancellations[0].isUpward)

        harness.move(harness.targetA, to: 640)
        await waitUntil(timeout: 2) { abs(actualReadingOffset(harness.targetA) - 200) < 2 }
        try #require(abs(actualReadingOffset(harness.targetA) - 200) < 2, "The downward move must settle at 200")
        for _ in 0 ..< 4 {
            view.configure(ids: ["changed"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 1)
            identity.deliver(harness.targetA)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs(actualReadingOffset(harness.targetA) - 200) < 2)

        view.configure(ids: ["changed"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 2)
        await waitUntil(timeout: 2) { abs(actualReadingOffset(harness.targetA) - 100) < 2 }
        #expect(abs(actualReadingOffset(harness.targetA) - 100) < 2)
    }

    @Test func givenProviderlessNumericRestoration_whenDownArrowArrives_thenCancellationReportsCurrentGeneration() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var cancellations: [(generation: Int, isUpward: Bool)] = []
        view.axis = .vertical
        view.usesNativeIdentity = true
        view.followsLive = false
        view.onRestorationCancelled = { context in
            cancellations.append((context.generation, context.isUpward))
            return context.generation
        }
        try #require(harness.window.makeFirstResponder(harness.targetA.contentView))
        let responder = try #require(harness.window.firstResponder as? NSView)
        #expect(responder === harness.targetA || responder.isDescendant(of: harness.targetA))
        view.configure(ids: [], stride: 0, restorationOffset: 100, restorationActive: true, generation: 7)
        identity.register(view)
        identity.deliver(harness.targetA)
        await Task.yield()
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil,
            characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
            isARepeat: false, keyCode: 125
        ))
        try #require(event.window === harness.window)
        let focused = try #require(harness.window.firstResponder as? NSView)
        #expect(focused === harness.targetA || focused.isDescendant(of: harness.targetA))
        view.observeNativeNavigationIntent(event)
        try #require(cancellations.count == 1)
        #expect(cancellations[0].generation == 7)
        #expect(!cancellations[0].isUpward)
    }

    @Test func givenFollowingRestoration_whenLiveScrollMovesUpAfterWillStart_thenCancellationIsUpwardAndSingleShot() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var cancellations: [(generation: Int, isUpward: Bool)] = []
        view.axis = .vertical
        view.usesNativeIdentity = true
        view.followsLive = true
        view.onRestorationCancelled = { context in
            cancellations.append((context.generation, context.isUpward))
            return context.generation
        }
        view.configure(ids: [], stride: 0, restorationOffset: 400, restorationActive: true, generation: 8)
        identity.register(view)
        identity.deliver(harness.targetA)
        await Task.yield()

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        await Task.yield()
        #expect(cancellations.isEmpty)
        harness.move(harness.targetA, to: 740)
        await Task.yield()
        view.adoptNativeIdentity(harness.targetA)
        await Task.yield()

        try #require(cancellations.count == 1)
        #expect(cancellations[0].generation == 8)
        #expect(cancellations[0].isUpward)
    }

    @Test func givenFollowingObserver_whenTenDownwardNativeTicksArrive_thenRestorationCancellationDoesNotChurn() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var cancellations: [(generation: Int, isUpward: Bool)] = []
        view.axis = .vertical
        view.usesNativeIdentity = true
        view.followsLive = true
        view.onRestorationCancelled = { context in
            cancellations.append((context.generation, context.isUpward))
            return context.generation
        }
        view.configure(ids: [], stride: 0, restorationOffset: 100, restorationActive: true, generation: 1)
        identity.register(view)
        identity.deliver(harness.targetA)
        await Task.yield()

        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: harness.targetA)
        for offset in stride(from: 740, through: 650, by: -10) {
            harness.move(harness.targetA, to: CGFloat(offset))
            await Task.yield()
        }

        #expect(cancellations.isEmpty)
    }

    @Test func givenOwnerAdvancesGenerationBeforeObserverConfigure_whenInputArrives_thenAcceptedWatermarkSuppressesOldConfigure() async throws {
        _ = NSApplication.shared
        let harness = try NativeIdentityHarness()
        defer { harness.close() }
        harness.targetA.scrollerStyle = .legacy
        harness.targetA.layoutSubtreeIfNeeded()
        let identity = ParallelScrollNativeIdentity()
        let view = harness.makeObserver()
        var ownerGeneration = 2
        var contexts: [ParallelScrollRestorationCancellation] = []
        var offsets: [CGFloat] = []
        view.axis = .vertical
        view.usesNativeIdentity = true
        view.followsLive = false
        view.onPosition = { offset, _, _ in offsets.append(offset) }
        view.onRestorationCancelled = { context in
            guard identity.isCurrentBinding(observer: context.observer, scrollView: context.scrollView) else {
                return nil
            }
            contexts.append(context)
            return ownerGeneration
        }
        view.configure(ids: [], stride: 0, restorationOffset: 100, restorationActive: true, generation: 1)
        identity.register(view)
        identity.deliver(harness.targetA)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 100) < 2 } }

        let obsoleteContext = ParallelScrollRestorationCancellation(
            observer: ParallelScrollObservationView(), scrollView: harness.targetB,
            generation: 99, isUpward: false)
        #expect(view.onRestorationCancelled?(obsoleteContext) == nil)

        let scroller = try #require(harness.targetA.verticalScroller)
        let knob = scroller.rect(for: .knob)
        let point = scroller.convert(NSPoint(x: knob.midX, y: knob.midY), to: nil)
        let event = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: harness.window.windowNumber, context: nil, eventNumber: 0,
            clickCount: 1, pressure: 1
        ))
        view.observeNativeNavigationIntent(event)
        try #require(contexts.count == 1)
        #expect(contexts[0].generation == 1)
        #expect(!contexts[0].isUpward)

        harness.move(harness.targetA, to: 640)
        await waitUntil(timeout: 2) { offsets.contains { abs($0 - 200) < 2 } }
        let beforeStaleConfigure = harness.targetA.documentVisibleRect
        view.configure(ids: ["stale"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 2)
        await Task.yield()
        #expect(harness.targetA.documentVisibleRect == beforeStaleConfigure)

        // A repeated native input after cancellation has no active work. It must not invoke the
        // owner again or downgrade the accepted generation watermark back to the stale request.
        view.configure(ids: ["lagging"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 1)
        await Task.yield()
        view.observeNativeNavigationIntent(event)
        #expect(contexts.count == 1)
        view.configure(ids: ["stale-again"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 2)
        await Task.yield()
        #expect(harness.targetA.documentVisibleRect == beforeStaleConfigure)

        ownerGeneration = 3
        view.configure(ids: ["fresh"], stride: 0, restorationOffset: 100, restorationActive: true, generation: 3)
        await waitUntil(timeout: 2) { abs(actualReadingOffset(harness.targetA) - 100) < 2 }
        #expect(abs(actualReadingOffset(harness.targetA) - 100) < 2)
    }

    private func actualReadingOffset(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .nan }
        return document.bounds.maxY - scroll.documentVisibleRect.maxY
    }

}
