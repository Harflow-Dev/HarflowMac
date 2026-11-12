import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// Opt-in production-view captures. The output is evidence for manual pixel inspection, not a pixel test.
extension ActivityFeedApprovalHostedTests {
    @Test func givenCaptureDirectory_whenCapturingTaskStates_thenCaptureActualWindows() async throws {
        guard let directory = try captureDirectory() else { return }
        for appearance in [ColorScheme.light, .dark] {
            for state in ["queued", "long", "multiple", "delivering", "refused", "undeliverable", "uncertain", "scrolled"] {
                try await captureTask(state: state, appearance: appearance, directory: directory)
            }
        }
    }

    @Test func givenCaptureDirectory_whenCapturingParallelQueue_thenCaptureActualWindows() async throws {
        guard let directory = try captureDirectory() else { return }
        for appearance in [ColorScheme.light, .dark] {
            try await captureParallel(appearance: appearance, directory: directory)
        }
    }

    @Test func givenCaptureDirectory_whenCapturingWorkflowLight_thenCaptureActualWindow() async throws {
        guard let directory = try captureDirectory() else { return }
        try await captureWorkflowFollow(appearance: .light, directory: directory)
    }

    @Test func givenCaptureDirectory_whenCapturingWorkflowDark_thenCaptureActualWindow() async throws {
        guard let directory = try captureDirectory() else { return }
        try await captureWorkflowFollow(appearance: .dark, directory: directory)
    }

    @Test func givenBlankActivityPaddingFocused_whenUpArrivesNearBottom_thenPauseSurvivesReconciliation() async throws {
        let model = WorkSurfaceWorkflowCaptureModel()
        model.count = 20
        let fixture = RedesignHost(WorkSurfaceWorkflowCaptureView(model: model), size: CGSize(width: 520, height: 700))
        defer { fixture.close() }
        try await foreground(fixture)

        var activity: WorkflowActivityNativeScrollView?
        await fixture.settle {
            activity = fixture.descendants.compactMap { $0 as? WorkflowActivityNativeScrollView }.first
            return activity?.owner?.positioned == true && activity.map { self.captureBottomGap($0) <= 3 } == true
                && fixture.hasStableRenderedFrame
        }
        let scroll = try #require(activity)
        let owner = try #require(scroll.owner)
        await fixture.settle { self.captureBottomGap(scroll) <= 3 && owner.positioned }
        try #require(captureBottomGap(scroll) <= 3)

        let clipPoint = CGPoint(x: scroll.contentView.bounds.minX + 2, y: scroll.contentView.bounds.midY)
        let documentPoint = try #require(scroll.documentView?.convert(clipPoint, from: scroll.contentView))
        try #require(documentPoint.x < HfRadius.Metrics.spacing16,
                     "The click must land in the activity document's leading padding")
        let windowPoint = scroll.contentView.convert(clipPoint, to: nil)
        let contentView = try #require(fixture.window.contentView)
        let hitView = try #require(contentView.hitTest(contentView.convert(windowPoint, from: nil)))
        var target: NSView? = hitView
        while let view = target, view !== scroll { target = view.superview }
        try #require(target === scroll, "The padding click must hit the mounted activity feed")

        let mouseDown = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
        ))
        let mouseUp = try #require(NSEvent.mouseEvent(
            with: .leftMouseUp, location: windowPoint, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0
        ))
        NSApp.postEvent(mouseUp, atStart: false)
        fixture.window.sendEvent(mouseDown)
        await fixture.settle { fixture.window.firstResponder === scroll }
        try #require(fixture.window.firstResponder === scroll,
                     "Clicking blank activity padding must give the feed keyboard focus")

        let offsetBeforeUp = owner.readingOffset
        fixture.window.sendEvent(try upArrowEvent(in: fixture.window))
        try #require(fixture.window.firstResponder === scroll)
        let gapAfterUp = captureBottomGap(scroll)
        try #require(!owner.following && owner.readingOffset < offsetBeforeUp && gapAfterUp > 0 && gapAfterUp <= 24,
                     "Up must pause within the near-bottom band: offset=\(owner.readingOffset), gap=\(gapAfterUp)")

        owner.reconcile()
        let pausedOffset = owner.readingOffset
        await fixture.settle {
            !owner.following && self.captureBottomGap(scroll) > 0 && self.captureBottomGap(scroll) <= 24
                && abs(owner.readingOffset - pausedOffset) < 0.5
        }
        let gapAfterReconcile = captureBottomGap(scroll)
        try #require(!owner.following && gapAfterReconcile > 0 && gapAfterReconcile <= 24
            && abs(owner.readingOffset - pausedOffset) < 0.5,
            "Reconciliation must retain the focused reader's near-bottom pause: offset=\(owner.readingOffset), gap=\(gapAfterReconcile)")
    }

    @Test func givenCaptureDirectory_whenCapturingWorkflowEditors_thenCaptureActualWindows() async throws {
        guard let directory = try captureDirectory() else { return }
        for appearance in [ColorScheme.light, .dark] {
            for (name, size) in [("narrow", CGSize(width: 1000, height: 700)), ("wide", CGSize(width: 1440, height: 900))] {
                try await captureEditor(name: name, size: size, appearance: appearance, directory: directory)
            }
        }
    }

    private func captureDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_WORK_SURFACE_CAPTURE_DIR"], !path.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func captureTask(state: String, appearance: ColorScheme, directory: URL) async throws {
        let vm = TaskDetailViewModelMock()
        let rows = (0 ..< 18).map { index in
            ConversationTimelineRow(id: "capture-\(index)", taskID: vm.taskID, timestamp: nil,
                kind: .item(PreviewFixtures.textItem("Activity \(index): reviewing the current changes.", seq: index)), live: true)
        }
        var timeline = TimelinePaneModel(stepCountText: "18 activity items", rows: rows, start: nil,
                                         emptyText: nil, subTaskStrip: nil, isLoading: false)
        let first = WorkMessageBubble(id: "first", seq: 1, kind: .queued(canCancel: true, note: nil), text: "Please check the tests too.")
        let second = WorkMessageBubble(id: "second", seq: 2, kind: .queued(canCancel: true, note: nil), text: "Then summarize the result.")
        switch state {
        case "multiple", "scrolled": timeline.workMessages = [first, second]
        case "long":
            timeline.workMessages = [.init(id: "first", seq: 1, kind: .queued(canCancel: true, note: nil),
                                           text: String(repeating: "Please check the tests and summarize the evidence. ", count: 12))]
        case "delivering": timeline.workMessages = [.init(id: "first", seq: 1, kind: .queued(canCancel: false, note: nil), text: first.text)]
        case "refused":
            let note = "Send now isn't available. This operation can't be interrupted safely."
            timeline.workMessages = [.init(id: "first", seq: 1, kind: .queued(canCancel: true, note: note), text: first.text)]
        case "undeliverable": timeline.workMessages = [.init(id: "first", seq: 1, kind: .undeliverable("The task has ended."), text: first.text)]
        case "uncertain": timeline.workMessages = [.init(id: "first", seq: 1, kind: .uncertain("Delivery could not be confirmed."), text: first.text)]
        default: timeline.workMessages = [first]
        }
        timeline.onCancelQueuedMessage = { _ in }
        vm.timelineModel = timeline
        try #require(vm.task != nil && vm.hasListed && !timeline.isLoading)
        let fixture = RedesignHost(
            TaskDetailView(vm).preferredColorScheme(appearance).environment(\.hfReduceMotionOverride, true),
            size: CGSize(width: 1000, height: 700), appearance: appearance
        )
        defer { fixture.close() }
        try await foreground(fixture)
        await fixture.settle { fixture.descendants.contains { $0 is ActivityFeedNativeTableView } }
        let table = try #require(fixture.descendants.compactMap { $0 as? ActivityFeedNativeTableView }.first)
        let scroll = try #require(table.enclosingScrollView)
        try await awaitTaskCaptureReady(fixture, table: table, expectedMessages: timeline.workMessages)
        if state == "scrolled" {
            activityNativeTestScroll(scroll, to: max(0, scroll.documentVisibleRect.minY - 300))
            await fixture.settle { fixture.element("Queued messages") != nil }
            try #require(fixture.element("Queued messages") != nil)
        }
        let owner = try #require(table.owner)
        let bottom = try #require(owner.entries.firstIndex(where: { $0.id == "activity-feed-bottom" }))
        print("WORK_SURFACE_CAPTURE state=\(state) appearance=\(appearance) bottomRow=\(table.rect(ofRow: bottom)) "
            + "visible=\(scroll.documentVisibleRect) table=\(table.bounds)")
        try screenCapture(fixture.window, to: directory.appendingPathComponent("task-\(state)-\(appearance).png"))
    }

    private func awaitTaskCaptureReady(_ fixture: RedesignHost, table: ActivityFeedNativeTableView,
                                       expectedMessages: [WorkMessageBubble]) async throws {
        func readiness() -> (bottom: Bool, queue: Bool, rendered: Bool) {
            let bottom = table.owner?.positioned == true && table.numberOfRows > 0
                && table.enclosingScrollView.map { abs(table.bounds.height - $0.documentVisibleRect.maxY) < 3 } == true
            let queue = table.owner?.entries.contains { entry in
                guard case .tail(.standard(let standard), _) = entry else { return false }
                return standard.workMessages == expectedMessages
            } == true
            return (bottom, queue, activityNativeVisibleTailHasRenderedContent(fixture.host))
        }
        await fixture.settle {
            let state = readiness()
            return state.bottom && state.queue && state.rendered && fixture.hasStableRenderedFrame
        }
        let state = readiness()
        let stable = fixture.hasStableRenderedFrame
        print("WORK_SURFACE_READINESS bottom=\(state.bottom) queue=\(state.queue) rendered=\(state.rendered) stable=\(stable)")
        try #require(state.bottom && state.queue && state.rendered && stable,
                     "Capture requires committed work messages, positioned live end, coherent tail geometry and stable rendered content")
    }

    private func captureParallel(appearance: ColorScheme, directory: URL) async throws {
        let task = try #require(TaskInfo(.object([
            "task_id": .string("capture-column"), "backend": .string("codex"),
            "status": .string("running"), "repo_path": .string("/tmp")
        ])))
        let rows = [ConversationTimelineRow(id: "capture-row", taskID: task.id, timestamp: nil,
            kind: .item(PreviewFixtures.textItem("Reviewing the activity.")), live: true)]
        var model = ParallelColumnModel(id: task.id, task: task, title: "Review", subtitle: "Codex",
            isBusy: false, outcomeMessage: nil, showPrompt: false,
            rows: rows, activityRows: ActivityRowsBuilder.build(from: rows), liveStep: nil,
            isLoading: false, summary: nil, onTapTakeover: {}, onTapOpenTask: {})
        model.workMessages = [.init(id: "column-message", seq: 1, kind: .queued(canCancel: true, note: nil),
                                    text: "Please check the tests too.")]
        model.onCancelMessage = { _ in }
        let fixture = RedesignHost(ParallelColumnView(model: model).preferredColorScheme(appearance),
                                   size: CGSize(width: 520, height: 700), appearance: appearance)
        defer { fixture.close() }
        try await foreground(fixture)
        await fixture.settle { fixture.element("Please check the tests too.") != nil }
        try #require(fixture.element("Please check the tests too.") != nil)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("parallel-queued-\(appearance).png"))
    }

    private func captureWorkflowFollow(appearance: ColorScheme, directory: URL) async throws {
        let model = WorkSurfaceWorkflowCaptureModel()
        let fixture = RedesignHost(WorkSurfaceWorkflowCaptureView(model: model).preferredColorScheme(appearance),
                                   size: CGSize(width: 520, height: 700), appearance: appearance)
        defer { fixture.close() }
        try await foreground(fixture)
        var scroll: WorkflowActivityNativeScrollView?
        await fixture.settle {
            scroll = fixture.descendants
                .compactMap { $0 as? WorkflowActivityNativeScrollView }
                .first { $0.identifier?.rawValue == "workflow-native-activity" && $0.documentView != nil }
            return scroll != nil
        }
        let feed = try #require(scroll)
        await fixture.settle { self.captureBottomGap(feed) <= 3 && (feed.documentView?.bounds.height ?? 0) > feed.contentView.bounds.height }
        try #require(captureBottomGap(feed) <= 3)
        let initialHeight = try #require(feed.documentView?.bounds.height)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("workflow-follow-before-\(appearance).png"))
        model.count = 20
        await fixture.settle { (feed.documentView?.bounds.height ?? 0) > initialHeight + 50 && self.captureBottomGap(feed) <= 3 }
        try #require((feed.documentView?.bounds.height ?? 0) > initialHeight + 50 && captureBottomGap(feed) <= 3)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("workflow-follow-after-\(appearance).png"))
        let preResizeViewport = feed.contentView.bounds.height
        let preResizeDocument = try #require(feed.documentView?.bounds.height)
        let preResizeOffset = feed.documentVisibleRect.minY
        let preResizeGap = captureBottomGap(feed)
        fixture.window.setContentSize(CGSize(width: 420, height: 340))
        await fixture.settle {
            feed.contentView.bounds.height < preResizeViewport - 50 && self.captureBottomGap(feed) <= 3
        }
        let resizedViewport = feed.contentView.bounds.height
        let resizedDocument = feed.documentView?.bounds.height ?? 0
        let resizedOffset = feed.documentVisibleRect.minY
        let resizedGap = captureBottomGap(feed)
        print("WORKFLOW_RESIZE_DIAGNOSTIC appearance=\(appearance) "
            + "before=(viewport:\(preResizeViewport), document:\(preResizeDocument), offset:\(preResizeOffset), gap:\(preResizeGap)) "
            + "after=(viewport:\(resizedViewport), document:\(resizedDocument), offset:\(resizedOffset), gap:\(resizedGap))")
        try screenCapture(fixture.window, to: directory.appendingPathComponent("workflow-follow-resized-\(appearance).png"))
        try #require(
            resizedViewport < preResizeViewport - 50 && resizedDocument > resizedViewport && resizedGap <= 3,
            "Resize must preserve pin: viewport=\(resizedViewport), document=\(resizedDocument), offset=\(resizedOffset), gap=\(resizedGap)"
        )
        try sendPageUp(feed, in: fixture.window)
        await fixture.settle { self.captureBottomGap(feed) > 24 }
        try #require(captureBottomGap(feed) > 24)
        let offset = feed.documentVisibleRect.minY
        let height = try #require(feed.documentView?.bounds.height)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("workflow-paused-before-\(appearance).png"))
        model.count = 24
        await fixture.settle {
            (feed.documentView?.bounds.height ?? 0) > height + 50
                && abs(feed.documentVisibleRect.minY - offset) < 4 && self.captureBottomGap(feed) > 24
        }
        try #require((feed.documentView?.bounds.height ?? 0) > height + 50
            && abs(feed.documentVisibleRect.minY - offset) < 4 && captureBottomGap(feed) > 24)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("workflow-paused-after-\(appearance).png"))
        print("ISSUE44_WORKFLOW_CAPTURE appearance=\(appearance) pausedOffset=\(offset) after=\(feed.documentVisibleRect.minY)")

        try await captureWorkflowQueuedJump(fixture: fixture, model: model, feed: feed, offset: offset,
                                            output: (appearance, directory))
    }

    private func captureWorkflowQueuedJump(fixture: RedesignHost, model: WorkSurfaceWorkflowCaptureModel,
                                           feed: NSScrollView, offset: CGFloat,
                                           output: (appearance: ColorScheme, directory: URL)) async throws {
        let pausedDocumentHeight = try #require(feed.documentView?.bounds.height)
        model.messages = [WorkMessageBubble(
            id: "capture-queued-jump", seq: 1, kind: .queued(canCancel: true, note: nil),
            text: "Please follow the newest output and review the resulting changes."
        )]
        func queuedJumpButton() -> NSObject? {
            fixture.descendants.flatMap(fixture.elements(in:)).first { element in
                fixture.matches(element, "Queued message") && fixture.string(element, "accessibilityRole") == "AXButton"
            }
        }
        await fixture.settle {
            (feed.documentView?.bounds.height ?? 0) > pausedDocumentHeight + 20
                && abs(feed.documentVisibleRect.minY - offset) < 4 && self.captureBottomGap(feed) > 24
                && queuedJumpButton() != nil
        }
        let queuedButton = try #require(queuedJumpButton())
        let queuedDocumentHeight = try #require(feed.documentView?.bounds.height)
        let queuedOffset = feed.documentVisibleRect.minY
        let queuedGap = captureBottomGap(feed)
        print("WORKFLOW_QUEUED_JUMP_DIAGNOSTIC appearance=\(output.appearance) "
            + "document=\(queuedDocumentHeight) offset=\(queuedOffset) gap=\(queuedGap)")
        try #require(queuedDocumentHeight > pausedDocumentHeight + 20
            && abs(queuedOffset - offset) < 4 && queuedGap > 24)
        try screenCapture(fixture.window, to: output.directory.appendingPathComponent("workflow-queued-jump-before-\(output.appearance).png"))
        try #require(fixture.press(queuedButton), "The queued-message jump must expose a press action")
        await fixture.settle { self.captureBottomGap(feed) <= 3 && queuedJumpButton() == nil }
        try #require(captureBottomGap(feed) <= 3 && queuedJumpButton() == nil)
        try screenCapture(fixture.window, to: output.directory.appendingPathComponent("workflow-queued-jump-after-\(output.appearance).png"))
    }

    private func captureBottomGap(_ scroll: NSScrollView) -> CGFloat {
        guard let document = scroll.documentView else { return .greatestFiniteMagnitude }
        return abs(document.bounds.maxY - scroll.documentVisibleRect.maxY)
    }

    private func sendPageUp(_ scroll: WorkflowActivityNativeScrollView, in window: NSWindow) throws {
        try #require(window.makeFirstResponder(scroll))
        try #require(window.firstResponder === scroll,
                     "Page Up requires the activity feed to be the actual window first responder")
        let owner = try #require(scroll.owner)
        let offsetBeforePageUp = owner.readingOffset
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F72C}",
            charactersIgnoringModifiers: "\u{F72C}", isARepeat: false, keyCode: 116
        ))
        window.sendEvent(event)
        try #require(window.firstResponder === scroll)
        try #require(!owner.following && owner.readingOffset < offsetBeforePageUp,
                     "A focused feed must handle Page Up through the window responder chain")
    }

    private func upArrowEvent(in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "\u{F700}",
            charactersIgnoringModifiers: "\u{F700}", isARepeat: false, keyCode: 126
        ))
    }

    private func captureEditor(name: String, size: CGSize, appearance: ColorScheme, directory: URL) async throws {
        let vm = WorkflowOnDemandPreview.make(orchestrator: true)
        vm.isEditing = true
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { vm.didDisappear(); fixture.close() }
        try await foreground(fixture)
        await fixture.settle { fixture.element("Standalone nodes, outside the workflow path") != nil }
        try #require(fixture.element("Standalone nodes, outside the workflow path") != nil)
        try screenCapture(fixture.window, to: directory.appendingPathComponent("editor-\(name)-\(appearance).png"))
    }

    private func foreground(_ fixture: RedesignHost) async throws {
        NSApp.setActivationPolicy(.regular)
        fixture.window.isOpaque = true
        fixture.window.backgroundColor = .windowBackgroundColor
        fixture.window.center()
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.window.isKeyWindow && NSApp.isActive }
        try #require(fixture.window.isKeyWindow && NSApp.isActive, "Capture requires a foreground key window")
    }

    private func screenCapture(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        let data = try Data(contentsOf: url)
        try #require(!data.isEmpty)
    }
}

@MainActor private final class WorkSurfaceWorkflowCaptureModel: ObservableObject {
    @Published var count = 12
    @Published var messages: [WorkMessageBubble] = []
}

@MainActor private struct WorkSurfaceWorkflowCaptureView: View {
    @ObservedObject var model: WorkSurfaceWorkflowCaptureModel

    var body: some View {
        let items = (0 ..< model.count).map {
            PreviewFixtures.textItem("Activity row \($0): " + String(repeating: "Output grows. ", count: 8), seq: $0)
        }
        let activity = WorkflowNativeActivityModel(executionID: "capture-execution", title: "Review", status: "running",
                                                   limited: false, items: items)
        VStack(spacing: 0) {
            WorkflowNativeActivityView(model: activity, messages: model.messages, onCancel: { _ in })
            MessageBoxView(model: .disabled) { _ in true }
        }
        .background(Color.windowBG)
    }
}
