import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct TaskDetailOverflowHostedTests {
    @Test func givenStandaloneOverflow_whenMenuActionsAreSelected_thenOrderedCommandsReachTheirHandlers() async throws {
        // given
        let vm = TaskDetailViewModelMock()
        vm.openParentTaskID = "parent"
        vm.ancestorCrumbs = [AncestorCrumb(id: "parent", title: "Parent title")]
        let task = try #require(vm.task)
        var invoked: [String] = []
        let actions = TaskDetailToolbarActions(
            takeover: { invoked.append("takeover") }, cancel: { invoked.append("stop") },
            copyResumeCommand: { invoked.append("resume") }, openTask: { invoked.append($0) },
            showRawEvents: { invoked.append("events") }, toggleInspector: {},
            copyTaskID: { invoked.append(task.taskID) }, openRepository: { invoked.append("finder") },
            copyRepoPath: { invoked.append("path") }
        )
        let controller = NSHostingController(rootView: NavigationStack {
            Text("Activity").background {
                TaskDetailToolbar(snapshot: TaskDetailToolbarSnapshot(vm, task: task, showsInspector: false, isRightPane: true), actions: actions)
            }
        })
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        await waitUntil { window.layoutIfNeeded(); return NSApp.isActive && window.isKeyWindow && window.toolbar?.items.isEmpty == false }
        #expect(window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "task-detail.takeover" } == false)
        let view = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "task-detail.more" }?.view)
        await waitUntil { Self.buttons(view).contains { $0 is NSPopUpButton } }
        let button = try #require(Self.buttons(view).first { $0 is NSPopUpButton })
        // when: open the actual SwiftUI Menu's native popup, capturing only its owned tracking notification.
        let capture = OverflowTrackingCapture(button: button)
        NotificationCenter.default.addObserver(capture, selector: #selector(OverflowTrackingCapture.didBegin(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(OverflowTrackingCapture.expire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .eventTracking)
        defer { deadline.invalidate(); NotificationCenter.default.removeObserver(capture); capture.menu?.cancelTracking() }
        button.performClick(nil)
        let menu = try #require(capture.menu)
        #expect(!capture.timedOut)
        let entries = menu.items.filter { !$0.isSeparatorItem }
        let repository = try #require(entries.first { $0.title == Format.repoName(task.repoPath) })
        menu.performActionForItem(at: try #require(menu.items.firstIndex(of: repository)))
        #expect(invoked.isEmpty, "The repository section heading must not dispatch an action")
        let commands = entries.filter { $0.title != Format.repoName(task.repoPath) }
        // then
        #expect(commands.map(\.title) == ["Stop task…", vm.takeoverButtonLabel, "Open parent task", "Copy resume command",
                                         "Copy task ID", "Open in Finder", "Copy path"])
        for command in commands {
            #expect(command.isEnabled)
            menu.performActionForItem(at: try #require(menu.items.firstIndex(of: command)))
        }
        #expect(invoked == ["stop", "takeover", "parent", "resume", task.taskID, "finder", "path"])
    }

    private static func buttons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
    }
}
