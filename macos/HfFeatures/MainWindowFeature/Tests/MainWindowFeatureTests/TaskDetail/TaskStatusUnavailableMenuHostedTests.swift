import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskStatusUnavailableHostedTests + Menu

extension TaskStatusUnavailableHostedTests {
    @Test func givenMountedUnavailableStatus_whenMoreMenuOpens_thenOnlyReadOnlyCommandsRemain() async throws {
        // given — the real VM has retained task data but its latest status attempt failed.
        let fixtures = TaskDetailVMTests.Fixtures()
        let fixture = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        let task = try #require(TaskInfo(.object([
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("running"),
            "repo_path": .string("/fixture/repository"), "session_id": .string("fixture-session"),
            "resume_command": .string("fixture resume command"),
            "spawned_by": .string("parent"), "live_input": .bool(true)
        ])))
        let parent = try #require(TaskInfo(.object(["task_id": .string("parent"), "backend": .string("claude"), "status": .string("running")])))
        fixture.detailBox.value = task
        fixture.snapshotBox.value = task
        fixtures.taskProvider.value = { $0 == "parent" ? parent : task }
        fixtures.ancestorsBox.value = [parent]
        fixtures.statusReadProvider.value = { _ in .init(revision: 2, task: nil) }
        var invoked: [String] = []
        let actions = TaskDetailToolbarActions(
            takeover: { invoked.append("terminal") }, cancel: { invoked.append("stop") },
            copyResumeCommand: { invoked.append("resume") }, openTask: { invoked.append($0) },
            showRawEvents: {}, toggleInspector: {}, copyTaskID: { invoked.append(task.taskID) },
            openRepository: { invoked.append("finder") }, copyRepoPath: { invoked.append("path") }
        )
        let root = UnavailableMenuHarness(sut: fixture.sut, actions: actions)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        defer { fixture.sut.didDisappear(); window.contentViewController = nil; window.close() }
        fixture.sut.didAppear()
        fixture.tasksSubject.send([task])
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        await waitUntil {
            window.layoutIfNeeded()
            return fixture.sut.isStatusUnavailable && window.toolbar?.items.contains { $0.itemIdentifier.rawValue == "task-detail.more" } == true
        }
        #expect(fixture.sut.openParentTaskID == "parent")
        let more = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "task-detail.more" }?.view)
        await waitUntil { Self.menuButtons(more).contains { $0 is NSPopUpButton } }
        let button = try #require(Self.menuButtons(more).first { $0 is NSPopUpButton })
        let capture = UnavailableMenuCapture(button: button)
        NotificationCenter.default.addObserver(capture, selector: #selector(UnavailableMenuCapture.didBegin(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(UnavailableMenuCapture.expire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .eventTracking)
        defer { deadline.invalidate(); NotificationCenter.default.removeObserver(capture); capture.menu?.cancelTracking() }

        // when — inspect the actual SwiftUI Menu's native tracking menu.
        button.performClick(nil)
        let menu = try #require(capture.menu)
        #expect(!capture.timedOut)
        let entries = menu.items.filter { !$0.isSeparatorItem }
        let commands = entries.filter { $0.title != Format.repoName(task.repoPath) }

        // then — no Stop, Terminal or resume command is present, while retained navigation stays usable.
        #expect(commands.map(\.title) == ["Open parent task", "Copy task ID", "Open in Finder", "Copy path"])
        for command in commands {
            #expect(command.isEnabled)
            menu.performActionForItem(at: try #require(menu.items.firstIndex(of: command)))
        }
        #expect(invoked == ["parent", task.taskID, "finder", "path"])
    }

    private static func menuButtons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(menuButtons)
    }
}

private struct UnavailableMenuHarness: View {
    @State var sut: TaskDetailVM
    let actions: TaskDetailToolbarActions
    var body: some View {
        NavigationStack {
            Text("Retained activity").background {
                if let task = sut.task {
                    TaskDetailToolbar(snapshot: TaskDetailToolbarSnapshot(sut, task: task, showsInspector: false, isRightPane: true), actions: actions)
                }
            }
        }
    }
}

@MainActor private final class UnavailableMenuCapture: NSObject {
    var menu: NSMenu?
    var timedOut = false
    weak var button: NSButton?
    init(button: NSButton) { self.button = button }

    @objc func didBegin(_ notification: Notification) {
        menu = notification.object as? NSMenu
        perform(#selector(closeTracking(_:)), with: nil, afterDelay: 0, inModes: [.eventTracking])
    }

    @objc func closeTracking(_: Any?) { escape(); menu?.cancelTracking() }

    @objc func expire(_: Timer) {
        timedOut = true
        escape()
        menu?.cancelTracking()
        button?.menu?.cancelTracking()
    }

    private func escape() {
        guard let window = button?.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: true)
    }
}
