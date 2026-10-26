import AppKit
import HfTestUtilities
@testable import HfUI
import SwiftUI
import Testing

// MARK: - SkeletonContentTests

@MainActor @Suite(.serialized) struct SkeletonContentTests {
    @Test func givenInitiallyReadyState_whenMounted_thenNoSkeletonHandoffIsPrepared() {
        // given / when
        let state = SkeletonContentState(isLoading: false)

        // then
        #expect(state.phase == .resolved)
        #expect(state.hasRevealed)
    }

    @Test func givenUnobservedExternalState_whenFirstResultIsReady_thenItResolvesWithoutFade() {
        // given
        let state = SkeletonContentState()

        // when
        state.resolveInitiallyReady()

        // then
        #expect(state.phase == .resolved)
        #expect(state.hasRevealed)
        #expect(!state.hasObservedLoading)
    }

    @Test func givenPreparedResult_whenLoadingRegresses_thenStaleRevealCannotApply() {
        // given
        let state = SkeletonContentState()
        let generation = state.prepare()
        #expect(state.phase == .prepared)
        #expect(!state.hasRevealed)

        // when
        state.invalidate()
        state.reveal(generation: generation, immediately: false)

        // then
        #expect(state.phase == .loading)
        #expect(!state.hasRevealed)
    }

    @Test func givenRevealedIdentity_whenLoadingRegresses_thenItDoesNotPrepareAnotherFade() {
        // given
        let state = SkeletonContentState()
        let generation = state.prepare()
        state.reveal(generation: generation, immediately: false)

        // when
        state.invalidate()
        _ = state.prepare()
        state.finish(generation: generation)

        // then
        #expect(state.hasRevealed)
        #expect(state.phase == .resolved)
    }

    @Test func givenReducedMotion_whenRevealing_thenSkeletonRetiresImmediately() {
        // given
        let state = SkeletonContentState()
        let generation = state.prepare()

        // when
        state.reveal(generation: generation, immediately: true)

        // then
        #expect(state.phase == .resolved)
        #expect(state.hasRevealed)
    }

    @Test func givenHostedHandoff_whenResultPreparesAndReveals_thenContentMountsOnlyOnceAndOverlayDoesNotOwnLayout() async {
        // given
        let gate = PreparationGate()
        let model = HostedModel(state: SkeletonContentState(waitForPresentedFrame: { await gate.wait() }))
        let fixture = HostedFixture(model: model)
        defer { fixture.close() }
        fixture.host.layoutSubtreeIfNeeded()
        await waitUntil { model.state.hasObservedLoading }
        #expect(model.contentMounts == 0)

        // when — preparation mounts the result without exposing it, then the real frame gate opens.
        model.isLoading = false
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return gate.entered && model.contentMounts == 1 }
        #expect(model.state.phase == .prepared)
        #expect(model.contentMounts == 1)
        let preparedSize = fixture.host.fittingSize
        #expect(model.placeholderMounts >= 2)
        #expect(model.placeholderUnmounts < model.placeholderMounts)
        #expect(fixture.frame(identifier: "handoff-placeholder")?.origin == fixture.frame(identifier: "handoff-result")?.origin)
        #expect(!fixture.accessibilityLabels.contains("Resolved fixture"))
        #expect(!fixture.accessibilityLabels.contains("Skeleton fixture"))
        gate.open()
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return model.state.phase == .resolved }

        // then — the same mounted result survives preparation, animation and overlay retirement.
        #expect(model.state.phase == .resolved)
        #expect(model.contentMounts == 1)
        #expect(model.contentUnmounts == 0)
        #expect(model.placeholderUnmounts == model.placeholderMounts)
        await waitUntil {
            fixture.host.layoutSubtreeIfNeeded()
            fixture.host.displayIfNeeded()
            return fixture.accessibilityLabels.contains("Resolved fixture")
        }
        #expect(fixture.accessibilityLabels.contains("Resolved fixture"))
        #expect(!fixture.accessibilityLabels.contains("Skeleton fixture"))
        #expect(fixture.host.fittingSize == preparedSize)
    }

    @Test func givenEmptyResult_whenOverlayRetires_thenNaturalEmptyLayoutRemainsEmpty() async {
        // given
        let gate = PreparationGate()
        let model = HostedModel(state: SkeletonContentState(waitForPresentedFrame: { await gate.wait() }))
        model.isEmpty = true
        let fixture = HostedFixture(model: model)
        defer { fixture.close() }
        await waitUntil { model.state.hasObservedLoading }

        // when
        model.isLoading = false
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return gate.entered }
        let preparedSize = fixture.host.fittingSize
        gate.open()
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return model.state.phase == .resolved }

        // then
        #expect(model.state.phase == .resolved)
        #expect(preparedSize == .zero)
        #expect(fixture.host.fittingSize == .zero)
    }

    @Test func givenHostedPreparation_whenRemovedBeforeFrame_thenCancelledWorkCannotReveal() async {
        // given
        let gate = PreparationGate()
        let model = HostedModel(state: SkeletonContentState(waitForPresentedFrame: { await gate.wait() }))
        let fixture = HostedFixture(model: model)
        await waitUntil { model.state.hasObservedLoading }
        model.isLoading = false
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return gate.entered }

        // when
        model.isMounted = false
        await waitUntil { fixture.host.layoutSubtreeIfNeeded(); return model.contentUnmounts == 1 }
        fixture.close()
        gate.open()
        await Task.yield()

        // then
        #expect(!model.state.hasRevealed)
    }
}

// MARK: - Hosted fixture

@MainActor @Observable private final class HostedModel {
    var isLoading = true
    var isMounted = true
    var isEmpty = false
    var placeholderMounts = 0
    var placeholderUnmounts = 0
    var contentMounts = 0
    var contentUnmounts = 0
    let state: SkeletonContentState

    init(state: SkeletonContentState) { self.state = state }
}

private struct HostedView: View {
    let model: HostedModel
    var body: some View {
        if model.isMounted {
            SkeletonContent(isLoading: model.isLoading, state: model.state) {
                Text("Skeleton fixture")
                    .frame(width: 200, height: 120)
                    .overlay { PlaceholderProbe(model: model) }
            } content: {
                if !model.isEmpty {
                    Text("Resolved fixture")
                        .frame(width: 80, height: 40)
                        .overlay { MountProbe(model: model) }
                }
            }
            .environment(\.hfReduceMotionOverride, false)
        }
    }
}

private struct PlaceholderProbe: NSViewRepresentable {
    let model: HostedModel
    func makeNSView(context _: Context) -> NSView {
        model.placeholderMounts += 1
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("handoff-placeholder")
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
    func makeCoordinator() -> HostedModel { model }
    static func dismantleNSView(_: NSView, coordinator: HostedModel) {
        coordinator.placeholderUnmounts += 1
    }
}

private struct MountProbe: NSViewRepresentable {
    let model: HostedModel
    func makeNSView(context _: Context) -> NSView {
        model.contentMounts += 1
        let view = NSView()
        view.identifier = NSUserInterfaceItemIdentifier("handoff-result")
        return view
    }

    func updateNSView(_: NSView, context _: Context) {}
    func makeCoordinator() -> HostedModel { model }
    static func dismantleNSView(_: NSView, coordinator: HostedModel) {
        coordinator.contentUnmounts += 1
    }
}

@MainActor private final class HostedFixture {
    let host: NSHostingView<HostedView>
    let window: NSWindow
    init(model: HostedModel) {
        _ = NSApplication.shared
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        self.host = NSHostingView(rootView: HostedView(model: model))
        self.window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 240, height: 160), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
    }

    func frame(identifier: String) -> CGRect? {
        func find(_ view: NSView) -> NSView? {
            if view.identifier?.rawValue == identifier { return view }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(host).map { $0.convert($0.bounds, to: host) }
    }

    var accessibilityLabels: Set<String> {
        var labels = Set<String>()
        var visited = Set<ObjectIdentifier>()
        func visit(_ object: NSObject) {
            guard visited.insert(ObjectIdentifier(object)).inserted else { return }
            for key in ["accessibilityValue", "accessibilityLabel", "accessibilityTitle"] where object.responds(to: NSSelectorFromString(key)) {
                if let value = object.value(forKey: key) as? String { labels.insert(value) }
            }
            if object.responds(to: NSSelectorFromString("accessibilityChildren")),
               let children = object.value(forKey: "accessibilityChildren") as? [NSObject] {
                children.forEach(visit)
            }
            if let view = object as? NSView { view.subviews.forEach(visit) }
        }
        visit(host)
        return labels
    }

    func close() { window.contentView = nil; window.close() }
}

@MainActor private final class PreparationGate {
    private(set) var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func open() { continuation?.resume(); continuation = nil }
}
