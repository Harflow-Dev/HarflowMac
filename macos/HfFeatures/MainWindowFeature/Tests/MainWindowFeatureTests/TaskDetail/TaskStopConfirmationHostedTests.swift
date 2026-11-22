import AppKit
import HfCommon
import HfCommonTestMock
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskStopConfirmationHostedTests

/// Uses the concrete task Stop builder, native sheet attachment observer, and shell-equivalent sheet binding without
/// mounting the full main-window repository graph. Production routing and stale-target fencing have unit coverage.
@MainActor @Suite(.serialized) struct TaskStopConfirmationHostedTests {
    @Test func givenNativeFocusRefusesStopSlot_whenRestoreIsAttempted_thenWorkingResponderRemains() async throws {
        let focusHost = MessageBoxStopFocusHost()
        let page = RedesignHost(StopFocusDenialHarness(host: focusHost).frame(width: 40, height: 32),
                                size: CGSize(width: 320, height: 160))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { focusHost.anchor?.window === page.window }
        let expectedTarget = try #require(focusHost.anchor?.subviews.first as? StopFocusDenialResponderView)
        let original = page.window.firstResponder
        var calls = 0
        var receivedWindow: NSWindow?
        var receivedTarget: NSResponder?
        focusHost.makeFirstResponder = { window, target in
            calls += 1
            receivedWindow = window
            receivedTarget = target
            return false
        }
        let restore = focusHost.captureReturn()

        #expect(restore() == false)
        #expect(calls == 1)
        #expect(receivedWindow === page.window)
        #expect(receivedTarget === expectedTarget)
        #expect(page.window.firstResponder === original)
    }

    @Test(arguments: [false, true])
    func givenLockedRetainedDraft_whenStopSheetIsCancelled_thenDraftSurvivesAndNativeFocusReturns(escape: Bool) async throws {
        // given
        let state = StopSheetState()
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .task("task")
        state.coordinator = coordinator
        let page = RedesignHost(CoordinatorStopSheetHarness(state: state, coordinator: coordinator),
                                size: CGSize(width: 1000, height: 700))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { page.element("Stop task") != nil }
        let slot = try #require(page.element("Stop task"))
        #expect(TaskStoppingHostedTests.isEnabled(slot) == true)
        let target = try nativeResponder(for: slot, in: page)
        let peer = try #require(state.peerResponder)
        #expect(peer.window === page.window)
        #expect(page.window.makeFirstResponder(peer))
        #expect(page.window.firstResponder === peer)

        // when
        #expect(page.press(slot))
        await page.settle { page.window.attachedSheet != nil }
        #expect(state.submissionCount == 0)
        let requestID = try #require(coordinator.stopConfirmation?.id)
        await page.settle { coordinator.taskStopDismissals[requestID] != nil }
        #expect(coordinator.presentedSheet == .stopTask)
        let sheet = try #require(page.window.attachedSheet)
        #expect(sheet.isKeyWindow)
        #expect(sheet.firstResponder !== peer)
        let root = try #require(sheet.contentView)
        func element(_ label: String) -> NSObject? { page.elements(in: root).first { page.matches($0, label) } }
        await page.settle { element("Keep running") != nil && sheet.firstResponder !== sheet }

        // then
        #expect(element("Stop this task?") != nil)
        #expect(element("Harflow asks this run and the tasks it started through Harflow to stop. This is best effort.") != nil)
        #expect(element("Files already written stay in place.") != nil)
        #expect(element("Builds and other background processes the run started can keep running. Harflow can't list them.") != nil)
        #expect(element("Won't be stopped by this") != nil)
        #expect(element("Started in earlier turns and running when the task list was last read:") != nil)
        #expect(element("Rebuild the index") != nil)
        #expect(element("From the task list, not from the engine's cancel result. May be out of date.") != nil)
        #expect(sheet.defaultButtonCell?.title != "Stop task")
        if escape {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(key)
        } else {
            #expect(page.press(try #require(element("Keep running"))))
        }
        await page.settle { page.window.attachedSheet == nil && state.restoreCount == 1 }
        #expect(state.confirmCount == 0)
        #expect(state.draft == "Keep my draft")
        #expect(state.submissionCount == 0)
        #expect(state.restoreCount == 1)
        #expect(page.window.firstResponder === target)

        try await verifyRestoredTargetActivatesStop(page: page, coordinator: coordinator, state: state,
                                                    target: target, previousRequestID: requestID)
    }

    private func verifyRestoredTargetActivatesStop(page: RedesignHost, coordinator: MainWindowCoordinator,
                                                   state: StopSheetState, target: NSView,
                                                   previousRequestID: UUID) async throws {
        let space = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: page.window.windowNumber, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
        NSApp.sendEvent(space)
        await page.settle { page.window.attachedSheet != nil }
        let reopenedID = try #require(coordinator.stopConfirmation?.id)
        #expect(reopenedID != previousRequestID)
        let reopened = try #require(page.window.attachedSheet)
        NSApp.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: reopened.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        await page.settle { page.window.attachedSheet == nil && state.restoreCount == 2 }
        #expect(page.window.firstResponder === target)
    }

    @Test func givenCapturedSheet_whenUnrelatedEndAndDetachBeforeCancelOccur_thenOnlyCancelledRequestRestoresOnce() async throws {
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .task("task")
        var restoreCount = 0
        let request = TaskStopConfirmation(conversationID: "task", taskID: "task", notStoppedTitles: [], confirm: {}) {
            restoreCount += 1
        }
        coordinator.presentStopConfirmation(request)
        let page = RedesignHost(Text("Sheet dismissal observer"), size: CGSize(width: 320, height: 160))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        let sheet = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        page.window.beginSheet(sheet, completionHandler: nil)
        defer {
            if sheet.sheetParent != nil { page.window.endSheet(sheet) }
            sheet.close()
        }
        await page.settle { page.window.attachedSheet === sheet }
        var dismissalCount = 0
        let observer = try #require(TaskStopSheetDismissal(window: sheet) {
            dismissalCount += 1
            if coordinator.cancelledTaskStop?.id == request.id {
                coordinator.taskStopSheetDidDismiss(requestID: request.id)
            }
        })
        coordinator.taskStopDismissals[request.id] = observer

        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: page.window)
        await page.settle { true }
        #expect(observer.isDetached == false)
        #expect(dismissalCount == 0)
        #expect(restoreCount == 0)

        page.window.endSheet(sheet)
        await page.settle { observer.isDetached }
        #expect(dismissalCount == 1)
        #expect(restoreCount == 0)
        coordinator.cancelStop(requestID: request.id)
        #expect(restoreCount == 1)
        NotificationCenter.default.post(name: NSWindow.didEndSheetNotification, object: page.window)
        await page.settle { true }
        #expect(dismissalCount == 1)
        #expect(restoreCount == 1)
    }

    @Test func givenNativeSheet_whenStopTaskIsPressed_thenConfirmationRunsOnceAndSheetCloses() async throws {
        // given
        let state = StopSheetState()
        let page = RedesignHost(StopSheetHarness(state: state), size: CGSize(width: 1000, height: 700))
        defer { page.close() }
        await page.settle { page.element("Stop") != nil }
        // when
        #expect(page.press(try #require(page.element("Stop"))))
        await page.settle { page.window.attachedSheet != nil }
        let root = try #require(page.window.attachedSheet?.contentView)
        await page.settle { page.elements(in: root).contains { page.matches($0, "Stop task") } }
        let button = try #require(page.elements(in: root).first { page.matches($0, "Stop task") })
        #expect(page.press(button))
        await page.settle { page.window.attachedSheet == nil }
        // then
        #expect(state.confirmCount == 1)
        #expect(page.element("Underlying task pane") != nil)
    }

    @Test(arguments: [MessageBoxStyle.standard, .transcript], [false, true])
    func givenOptionalStopAction_whenComposerIsMounted_thenOnlyTranscriptShowsStopAndBusyDisablesIt(style: MessageBoxStyle, busy: Bool) async throws {
        // given
        var count = 0
        let model = MessageBoxModel(canSend: false, canContinue: false, isBusy: busy, label: "Messages", hint: "",
                                    placeholder: "Unavailable", buttonLabel: "Send", stopAction: { count += 1 })
        let page = RedesignHost(MessageBoxView(model: model, style: style) { _ in false }, size: CGSize(width: 900, height: 200))
        defer { page.close() }
        // when
        var passes = 0
        await page.settle { passes += 1; return passes >= 8 }
        let stop = page.element("Stop")
        // then
        if style == .standard {
            #expect(stop == nil)
        } else {
            let stop = try #require(stop)
            #expect(try #require(Self.isEnabled(stop)) == !busy)
            if !busy {
                #expect(page.press(stop))
                #expect(count == 1)
            }
        }
    }

    private static func isEnabled(_ object: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard object.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        let getter = unsafeBitCast(object.method(for: selector), to: Getter.self)
        return getter(object, selector)
    }

    private func nativeResponder(for object: NSObject, in page: RedesignHost) throws -> NSView {
        let expected = try #require(page.frame(object))
        var matches: [NSView] = []
        func visit(_ view: NSView) {
            let frame = view.convert(view.bounds, to: nil)
            if view.acceptsFirstResponder,
               abs(frame.midX - expected.midX) < 2, abs(frame.midY - expected.midY) < 2,
               abs(frame.width - expected.width) < 4, abs(frame.height - expected.height) < 4 {
                matches.append(view)
            }
            view.subviews.forEach(visit)
        }
        visit(try #require(page.window.contentView))
        return try #require(matches.count == 1 ? matches.first : nil,
                            "expected one native responder aligned with the standalone Stop slot, found \(matches.count)")
    }
}

// MARK: - StopSheetState

@Observable @MainActor private final class StopSheetState {
    var request: TaskStopConfirmation?
    var confirmCount = 0
    var submissionCount = 0
    var draft = "Keep my draft"
    var restoreCount = 0
    var peerResponder: NSView?
    var coordinator: MainWindowCoordinator?

    func open() {
        request = TaskStopConfirmation(conversationID: "conversation", taskID: "task", notStoppedTitles: ["Rebuild the index"], confirm: {})
    }

    func requestStop(restoring focus: @escaping @MainActor () -> Void) {
        coordinator?.presentStopConfirmation(TaskStopConfirmation(
            conversationID: "task", taskID: "task", notStoppedTitles: ["Rebuild the index"],
            confirm: { self.confirmCount += 1 },
            cancelDidDismiss: { self.restoreCount += 1; focus() }
        ))
    }

}

// MARK: - StopSheetHarness

private struct StopSheetHarness: View {
    @Bindable var state: StopSheetState
    var body: some View {
        VStack {
            Text("Underlying task pane")
            MessageBoxView(model: MessageBoxModel(canSend: true, canContinue: false, isBusy: false,
                                                 label: "Messages", hint: "", placeholder: "Queue a message…", buttonLabel: "Send",
                                                 stopAction: { state.open() }), style: .transcript) { _ in false }
        }
        .sheet(item: $state.request) { request in
            TaskStopConfirmationView(confirmation: request) {
                guard state.request?.id == request.id else { return }
                state.request = nil
                state.confirmCount += 1
            }
        }
    }
}

private struct CoordinatorStopSheetHarness: View {
    @Bindable var state: StopSheetState
    let coordinator: MainWindowCoordinator

    var body: some View {
        VStack {
            Text("Underlying task pane")
            StopFocusPeer { state.peerResponder = $0 }
                .frame(width: 40, height: 32)
            MessageBoxView(model: Self.model(state: state), style: .transcript, isStandalone: true,
                           text: $state.draft) { _ in state.submissionCount += 1; return false }
        }
        // Fill the window like the shell does, so the hosting view does not shrink its window to fit the content.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .sheet(item: Binding(get: { coordinator.presentedSheet }, set: { sheet in
            if let sheet { coordinator.presentedSheet = sheet } else { coordinator.dismissPresentedSheet() }
        }), onDismiss: { coordinator.pendingLaunchStopSheetDidDismiss() }) { sheet in
            switch sheet {
            case .stopTask: coordinator.buildStopConfirmationView()
            default: EmptyView()
            }
        }
    }

    private static func model(state: StopSheetState) -> MessageBoxModel {
        var model = MessageBoxModel(canSend: false, canContinue: false, isBusy: false,
            label: "Messages", hint: "", placeholder: MessageBoxDisabledReason.takenOver.text,
            buttonLabel: "Send", isLocked: true)
        model.isRunning = true
        model.stopAction = { state.open() }
        model.stopWithFocusAction = { state.requestStop(restoring: $0) }
        return model
    }
}

@MainActor private struct StopFocusPeer: NSViewRepresentable {
    let onCreate: (NSView) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = StopFocusPeerView(frame: NSRect(x: 0, y: 0, width: 40, height: 32))
        onCreate(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { onCreate(view) }
}

@MainActor private final class StopFocusPeerView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

@MainActor private struct StopFocusDenialHarness: NSViewRepresentable {
    let host: MessageBoxStopFocusHost
    func makeNSView(context: Context) -> NSView {
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 32))
        anchor.addSubview(StopFocusDenialResponderView(frame: anchor.bounds))
        host.anchor = anchor
        host.eligible = true
        return anchor
    }

    func updateNSView(_ view: NSView, context: Context) { host.anchor = view; host.eligible = true }
}

@MainActor private final class StopFocusDenialResponderView: NSView {
    override var acceptsFirstResponder: Bool { true }
}
