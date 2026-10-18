//
//  DeferredContent.swift
//  PbUI
//
//  Monitor piece 12: picking a new task/group used to render nothing for a split second — the
//  detail pane's SwiftUI layout (`NSHostingView.layout`, text measurement) ran synchronously in the
//  very same runloop turn as the selection, so neither a skeleton nor the new content ever got a
//  frame before the heavy build finished. `DeferredContent` shows `placeholder` on the first frame
//  (cheap: SwiftUI never evaluates the `content` branch until it is the one being rendered), then
//  swaps to `content` once that first frame has actually been committed — so the selection change is
//  visible instantly, and the expensive layout happens on the frame after.
//

import AppKit
import QuartzCore
import SwiftUI

// MARK: - DeferredContentState

/// The state machine behind `DeferredContent`, pulled out so it is testable without a SwiftUI
/// rendering harness (a `View`'s own `@State` can't be inspected directly). Starts on the
/// placeholder; `revealAfterFirstFrame()` waits until the placeholder has been presented, then
/// flips to content.
@MainActor
@Observable
public final class DeferredContentState {
    public private(set) var isShowingContent = false
    @ObservationIgnored private let waitForPresentedFrame: @MainActor () async -> Void

    /// Waits on real display refreshes (`DisplayFrames.waitForPresentedFrame`).
    public convenience init() {
        self.init(waitForPresentedFrame: DisplayFrames.waitForPresentedFrame)
    }

    /// `waitForPresentedFrame` is injectable so tests need no display.
    public init(waitForPresentedFrame: @escaping @MainActor () async -> Void) {
        self.waitForPresentedFrame = waitForPresentedFrame
    }

    public func revealAfterFirstFrame() async {
        guard !isShowingContent else { return }
        await waitForPresentedFrame()
        isShowingContent = true
    }
}

// MARK: - DisplayFrames

/// Suspends until the window server has presented a frame drawn after the call.
///
/// `Task.yield()`/`Task.sleep` only suspend the task — nothing ties their resumption to SwiftUI's
/// commit, so the swap could still land before the placeholder is ever drawn (Codex review, piece
/// 12). A display link fires once per refresh: the transaction holding the placeholder is committed
/// at the end of the run-loop turn that rendered it, so it is on screen by the second tick at the
/// latest. A display that stops refreshing (disconnected, asleep) must not strand the placeholder,
/// so a short timeout and task cancellation also end the wait — whichever comes first, once.
/// Without a screen (headless, tests) a main-queue hop is the best available boundary.
public enum DisplayFrames {
    static let timeout: TimeInterval = 0.1

    @MainActor
    public static func waitForPresentedFrame() async {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            return
        }
        let waiter = FrameWaiter(screen: screen, ticks: 2, timeout: timeout)
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in waiter.start { continuation.resume() } }
        } onCancel: {
            Task { @MainActor in waiter.finish() }
        }
    }
}

// MARK: - FrameWaiter

/// Keeps itself alive through its display link until it finishes — after `ticks` refreshes, the
/// timeout, or `finish()`, exactly once.
@MainActor
private final class FrameWaiter: NSObject {
    private var remaining: Int
    private var link: CADisplayLink?
    private var selfRetain: FrameWaiter?
    private var completion: (() -> Void)?
    private var isFinished = false
    private let screen: NSScreen
    private let timeout: TimeInterval

    init(screen: NSScreen, ticks: Int, timeout: TimeInterval) {
        self.screen = screen
        self.remaining = ticks
        self.timeout = timeout
    }

    func start(completion: @escaping () -> Void) {
        // Cancelled before the continuation existed: resume at once.
        guard !isFinished else { return completion() }
        self.completion = completion
        selfRetain = self
        let link = screen.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in self?.finish() }
    }

    func finish() {
        guard !isFinished else { return }
        isFinished = true
        link?.invalidate()
        link = nil
        completion?()
        completion = nil
        selfRetain = nil
    }

    @objc private func tick() {
        remaining -= 1
        if remaining <= 0 { finish() }
    }
}

// MARK: - DeferredContent

/// Renders `placeholder` on its first frame, then swaps to `content` one committed frame later.
/// Callers key this at the identity that should reset it (a coordinator's per-selection `.id()`,
/// wrapping the whole screen) — a fresh `DeferredContentState` is created whenever that identity
/// changes, so every new selection starts on the placeholder again, while a re-render of the SAME
/// selection (state changing elsewhere) never re-triggers the swap and so never flashes the
/// placeholder a second time.
public struct DeferredContent<Placeholder: View, Content: View>: View {
    @State private var state = DeferredContentState()
    private let placeholder: () -> Placeholder
    private let content: () -> Content

    public init(@ViewBuilder placeholder: @escaping () -> Placeholder, @ViewBuilder content: @escaping () -> Content) {
        self.placeholder = placeholder
        self.content = content
    }

    public var body: some View {
        Group {
            if state.isShowingContent {
                content()
            } else {
                placeholder()
            }
        }
        .task { await state.revealAfterFirstFrame() }
    }
}

#if DEBUG
#Preview("DeferredContent") {
    DeferredContent {
        SkeletonRows(count: 4)
    } content: {
        VStack(alignment: .leading, spacing: 8) {
            Text("Real content").font(.pb(.headline, weight: .semibold))
            Text("This replaces the skeleton one committed frame after it first renders.")
                .foregroundStyle(.secondary)
        }
    }
    .padding()
    .frame(width: 320)
}
#endif
