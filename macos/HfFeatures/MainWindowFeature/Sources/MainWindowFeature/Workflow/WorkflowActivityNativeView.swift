import AppKit
import HfUI
import SwiftUI

// MARK: - WorkflowActivityPresentation

struct WorkflowActivityPresentation: Equatable {
    let model: WorkflowNativeActivityModel
    let messages: [WorkMessageBubble]
    let isCancelDisabled: Bool
    var hasCancel = false
}

// MARK: - WorkflowActivityActions

/// Stable callbacks let identical updates refresh actions without replacing hosted content.
@MainActor final class WorkflowActivityActions {
    var cancel: ((String) -> Void)?
    var jump: () -> Void = {}
    var following: (Bool) -> Void = { _ in }
    var height: (CGFloat, Int, Int) -> Void = { _, _, _ in }
    var openURL = EnvironmentValues().openURL

    func reset() {
        cancel = nil
        jump = {}
        following = { _ in }
        height = { _, _, _ in }
        openURL = EnvironmentValues().openURL
    }
}

// MARK: - WorkflowActivityHostedRoot

struct WorkflowActivityHostedRoot: View {
    let presentation: WorkflowActivityPresentation
    let environment: ActivityFeedNativeEnvironment
    let actions: WorkflowActivityActions
    let width: CGFloat
    let revision: Int
    let attachmentGeneration: Int

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .modifier(ActivityFeedNativeInheritedEnvironment(environment: environment))
            .environment(\.openURL, OpenURLAction { url in
                actions.openURL(url)
                return .handled
            })
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                actions.height(height, revision, attachmentGeneration)
            }
    }

    private var content: some View {
        let model = presentation.model
        let settled = presentation.messages.filter { !$0.isPinned }
        let pinned = presentation.messages.filter(\.isPinned)
        return VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
            Text(model.title + " · Subagent").font(.hf(.body, weight: .semibold))
            Text(model.status).font(.hf(.caption)).foregroundStyle(Color.secondaryText)
            if model.limited { Text("Activity limited").font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
            if let error = model.error { Text(error).font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
            if model.hasEarlierActivity { Text("Showing the latest 200 activity events.").font(.hf(.caption)).foregroundStyle(Color.secondaryText) }
            ForEach(model.items) { item in
                TimelineRow(model: TimelineRowModel(item: item, start: nil,
                    live: ["running", "launch_requested"].contains(model.status), markdown: model.markdown[item.id]))
            }
            if !settled.isEmpty { WorkMessageBubblesView(bubbles: settled) }
            if !pinned.isEmpty {
                WorkMessageBubblesView(bubbles: pinned, onCancel: presentation.hasCancel ? { actions.cancel?($0) } : nil,
                                       isCancelDisabled: presentation.isCancelDisabled)
                    .id("queued-messages")
            }
        }
        .padding(HfRadius.Metrics.spacing16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - WorkflowActivityNativeView

struct WorkflowActivityNativeView: NSViewRepresentable {
    let presentation: WorkflowActivityPresentation
    let actions: WorkflowActivityActions
    let onCancel: ((String) -> Void)?
    let onFollowing: (Bool) -> Void

    func makeCoordinator() -> WorkflowActivityScrollOwner { WorkflowActivityScrollOwner() }

    func makeNSView(context: Context) -> WorkflowActivityNativeScrollView {
        let scroll = WorkflowActivityNativeScrollView()
        context.coordinator.install(scroll: scroll, actions: actions)
        return scroll
    }

    func updateNSView(_ scroll: WorkflowActivityNativeScrollView, context: Context) {
        actions.cancel = onCancel
        actions.following = onFollowing
        actions.openURL = context.environment.openURL
        context.coordinator.update(presentation: presentation, environment: context.environment)
    }

    static func dismantleNSView(_: WorkflowActivityNativeScrollView, coordinator: WorkflowActivityScrollOwner) {
        coordinator.stop()
    }
}

// MARK: - WorkflowActivityDocumentView

/// Top-origin natural document geometry is owned exclusively by the native coordinator.
@MainActor final class WorkflowActivityDocumentView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - WorkflowActivityNativeScrollView

@MainActor final class WorkflowActivityNativeScrollView: NSScrollView {
    weak var owner: WorkflowActivityScrollOwner?

    // Attribution is scoped to synchronous input dispatch and its synchronous bounds changes.
    // Responsive scrolling would move that work off-thread and outside the owned dispatch.
    override static var isCompatibleWithResponsiveScrolling: Bool { false }
    override var acceptsFirstResponder: Bool { true }

    // The owned feed handles navigation itself. Inherited scroll-view focus forwarding
    // cannot hand focus to this non-focusable document container.
    override func becomeFirstResponder() -> Bool { true }

    override func scrollWheel(with event: NSEvent) {
        guard let owner else { super.scrollWheel(with: event); return }
        owner.wheelPhase(event)
        owner.beginInput(upward: event.scrollingDeltaY > 0)
        defer { owner.endInput() }
        super.scrollWheel(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if owner?.handleKey(event) == true { return }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        owner?.attachmentChanged()
    }
}

// MARK: - WorkflowActivityNativeScroller

/// Mirrors the owned activity feed's native scroller intent without replacing AppKit tracking.
@MainActor final class WorkflowActivityNativeScroller: NSScroller {
    override static var isCompatibleWithOverlayScrollers: Bool { true }
    weak var owner: WorkflowActivityScrollOwner?
    private var previousValue: Double = 0

    override func mouseDown(with event: NSEvent) {
        previousValue = doubleValue
        owner?.setScrollerTracking(true)
        defer { owner?.setScrollerTracking(false) }
        super.mouseDown(with: event)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        owner?.beginInput(upward: hitPart == .decrementPage || (hitPart == .knob && doubleValue < previousValue))
        defer { owner?.endInput() }
        previousValue = doubleValue
        return super.sendAction(action, to: target)
    }
}
