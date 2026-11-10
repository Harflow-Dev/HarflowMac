import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskStopConfirmationHostedTests

/// Native sheets over an inert, mounted composer. Production routing and stale-target fencing have unit coverage.
@MainActor @Suite(.serialized) struct TaskStopConfirmationHostedTests {
    @Test(arguments: [false, true])
    func givenDraft_whenStopSheetIsDismissed_thenCopyIsApprovedAndDraftSurvives(escape: Bool) async throws {
        // given
        let state = StopSheetState()
        let page = RedesignHost(StopSheetHarness(state: state), size: CGSize(width: 1000, height: 700))
        defer { page.close() }
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await page.settle { MessageBoxTranscriptStyleHostedTests.editableField(in: page) != nil }
        let field = try #require(MessageBoxTranscriptStyleHostedTests.editableField(in: page))
        await MessageBoxTranscriptStyleHostedTests.type("Keep my draft", into: field, in: page)

        // when
        #expect(page.press(try #require(page.element("Stop"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        let root = try #require(sheet.contentView)
        func element(_ label: String) -> NSObject? { page.elements(in: root).first { page.matches($0, label) } }
        await page.settle { element("Keep running") != nil }

        // then
        #expect(element("Stop this task?") != nil)
        #expect(element("Harflow asks this run and the tasks it started through Harflow to stop. This is best effort.") != nil)
        #expect(element("Files already written stay in place.") != nil)
        #expect(element("Builds and other background processes the run started can keep running. Harflow can't list them.") != nil)
        #expect(element("Won't be stopped by this") != nil)
        #expect(element("Started in earlier turns and running when the task list was last read:") != nil)
        #expect(element("Rebuild the index") != nil)
        #expect(element("From the task list, not from the engine's cancel result. May be out of date.") != nil)
        #expect(field.window === page.window)
        #expect(sheet.defaultButtonCell?.title != "Stop task")
        if escape {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                  windowNumber: sheet.windowNumber, context: nil, characters: "\u{1b}",
                                                  charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
            NSApp.sendEvent(key)
        } else {
            #expect(page.press(try #require(element("Keep running"))))
        }
        await page.settle { page.window.attachedSheet == nil }
        #expect(state.confirmCount == 0)
        #expect(field.stringValue == "Keep my draft")
        #expect(field.window === page.window)
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
}

// MARK: - StopSheetState

@Observable @MainActor private final class StopSheetState {
    var request: TaskStopConfirmation?
    var confirmCount = 0
    func open() {
        request = TaskStopConfirmation(conversationID: "conversation", taskID: "task", notStoppedTitles: ["Rebuild the index"], confirm: {})
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
