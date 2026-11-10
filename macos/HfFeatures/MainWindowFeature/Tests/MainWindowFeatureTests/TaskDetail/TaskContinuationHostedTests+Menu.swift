import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskContinuationHostedTests + Menu

extension TaskContinuationHostedTests {
    /// Mount the real toolbar snapshot from the uncertain real VM, then inspect SwiftUI Menu's native items.
    func assertUncertainNativeMenu(_ fixture: HostedContinuationFixture) async throws {
        let task = try #require(fixture.vm.sut.task)
        var readActions: [String] = []
        let actions = TaskDetailToolbarActions(
            takeover: fixture.vm.sut.didTapTakeover, cancel: fixture.vm.sut.didTapCancel,
            copyResumeCommand: fixture.vm.sut.didTapCopyResumeCommand, openTask: { readActions.append($0) },
            showRawEvents: {}, toggleInspector: {}, copyTaskID: { readActions.append("id") },
            openRepository: { readActions.append("repository") }, copyRepoPath: { readActions.append("path") })
        let snapshot = TaskDetailToolbarSnapshot(fixture.vm.sut, task: task, showsInspector: false, isRightPane: true)
        let controller = NSHostingController(rootView: NavigationStack {
            Text("Read-only task context").background { TaskDetailToolbar(snapshot: snapshot, actions: actions) }
        })
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.makeKeyAndOrderFront(nil)
        defer { window.contentViewController = nil; window.close() }
        await waitUntil { window.layoutIfNeeded(); return window.toolbar?.items.isEmpty == false }
        let itemView = try #require(window.toolbar?.items.first { $0.itemIdentifier.rawValue == "task-detail.more" }?.view)
        await waitUntil { Self.menuButtons(itemView).contains { $0 is NSPopUpButton } }
        let button = try #require(Self.menuButtons(itemView).first { $0 is NSPopUpButton })
        let capture = ContinuationMenuCapture(button: button)
        NotificationCenter.default.addObserver(capture, selector: #selector(ContinuationMenuCapture.didBegin(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(ContinuationMenuCapture.expire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .eventTracking)
        defer { deadline.invalidate(); NotificationCenter.default.removeObserver(capture); capture.menu?.cancelTracking() }
        button.performClick(nil)
        let menu = try #require(capture.menu)
        #expect(!capture.timedOut)
        for item in menu.items where ["Stop task…", "Take over", "Copy resume command"].contains(item.title) {
            #expect(!item.isEnabled, "Uncertain Continue must suppress or disable \(item.title)")
        }
        for title in ["Copy task ID", "Open in Finder", "Copy path"] {
            let item = try #require(menu.items.first { $0.title == title })
            #expect(item.isEnabled)
            let index = try #require(menu.items.firstIndex(of: item))
            menu.performActionForItem(at: index)
        }
        #expect(readActions == ["id", "repository", "path"])
    }

    private static func menuButtons(_ view: NSView) -> [NSButton] {
        (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(menuButtons)
    }
}

// MARK: - ContinuationMenuCapture

@MainActor private final class ContinuationMenuCapture: NSObject {
    var menu: NSMenu?
    var timedOut = false
    weak var button: NSButton?
    init(button: NSButton) { self.button = button }

    @objc func didBegin(_ notification: Notification) {
        menu = notification.object as? NSMenu
        perform(#selector(closeTracking(_:)), with: nil, afterDelay: 0, inModes: [.eventTracking])
    }

    @objc func closeTracking(_: Any?) { escape(); menu?.cancelTracking() }
    @objc func expire(_: Timer) { timedOut = true; escape(); menu?.cancelTracking(); button?.menu?.cancelTracking() }

    private func escape() {
        guard let window = button?.window,
              let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                                          isARepeat: false, keyCode: 53) else { return }
        NSApp.postEvent(event, atStart: true)
    }
}
