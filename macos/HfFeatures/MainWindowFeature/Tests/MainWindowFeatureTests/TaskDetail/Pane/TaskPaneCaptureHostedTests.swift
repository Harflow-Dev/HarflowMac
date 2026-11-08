import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskPaneCaptureHostedTests

/// Optional review captures (`HARFLOW_M05_PANE_CAPTURE_DIR`) of the standalone right pane over preview models, light
/// and dark, at 1280x800 and 1000x620: split, overlay, Events with every group expanded, and Artifacts. They are
/// evidence for separate visual review and assert only that the owned window rendered the expected pane.
///
/// The hosted window has no sidebar, so the overlay captures reserve a neutral rail of the width the sidebar takes
/// (400 points at 1280, 272 at 1000), which leaves the detail column below 900 points as in the app. The other
/// captures use the whole window.
@MainActor @Suite(.serialized) struct TaskPaneCaptureHostedTests {
    enum PaneCapture: String, CaseIterable, CustomTestStringConvertible {
        case split, overlay, eventsExpanded = "events-expanded", artifacts
        var testDescription: String { rawValue }
    }

    static let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)]

    func mock(for capture: PaneCapture) -> TaskDetailViewModelMock {
        switch capture {
        case .split, .overlay: PaneMocks.done(exit: 0, notices: ["Checkout is on the default branch."])
        case .eventsExpanded: PaneMocks.continuity(notices: ["Checkout is on the default branch."])
        case .artifacts:
            {
                let mock = PaneMocks.done(exit: 0)
                mock.artifactMembers = [ArtifactMemberModel(id: PaneMocks.taskID)]
                return mock
            }()
        }
    }

    func store(for capture: PaneCapture) -> TaskPaneStateStore {
        let store = TaskPaneStateStore()
        let id = "conv"
        switch capture {
        case .split:
            break // the default: a done task with an observed exit opens at split width
        case .overlay:
            store.setOpenChoice(.open, for: id)
            store.setSelectedTab(.events, for: id)
            store.setGroup(.task, expanded: true, for: id)
        case .eventsExpanded:
            store.setOpenChoice(.open, for: id)
            store.setSelectedTab(.events, for: id)
            store.setExpandedGroups([.task, .enforcement, .notices, .continuity, .usage], for: id)
            store.setTechnicalInfoExpanded(true, for: id)
        case .artifacts:
            store.setOpenChoice(.open, for: id)
            store.setSelectedTab(.artifacts, for: id)
        }
        return store
    }

    @Test(arguments: PaneCapture.allCases, [false, true])
    func givenPaneState_whenCaptureDirectorySet_thenTheTaskScreenIsCapturedInBothSizes(capture: PaneCapture, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_PANE_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for size in Self.sizes {
            // given
            _ = NSApplication.shared
            let rail: CGFloat = capture == .overlay ? (size.width > 1100 ? 400 : 272) : 0
            let detail = PaneMocks.standalone(mock(for: capture), store: store(for: capture))
            let root = HStack(spacing: 0) {
                if rail > 0 { Rectangle().fill(Color.gray.opacity(0.12)).frame(width: rail) }
                NavigationStack { detail }.frame(maxWidth: .infinity)
            }
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true)
            let controller = NSHostingController(rootView: root)
            controller.sceneBridgingOptions = .all
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentViewController = controller
            window.setContentSize(size)
            window.orderFront(nil)
            window.makeKey()
            defer { window.contentViewController = nil; window.close() }
            let host = controller.view
            // The activation is re-asserted while waiting: a one-off request can be lost to another application.
            await waitUntil(timeout: 15) {
                if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
                if !window.isKeyWindow { window.makeKey() }
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                return NSApp.isActive && window.isKeyWindow
            }
            var passes = 0
            await waitUntil(timeout: 8) {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                passes += 1
                return passes >= 60
            }
            await DisplayFrames.waitForPresentedFrame()

            // then — the pane the capture is named for is on screen
            let labels = host.accessibilityChildrenDeep()
            #expect(labels.contains("Task details"), "no pane in \(capture.rawValue)")
            #expect(labels.contains("Close right pane"))
            if capture == .eventsExpanded { #expect(labels.contains("Continuity")) }
            let name = "m05-g1a-pane-\(capture.rawValue)-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
            try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
        }
    }
}

private extension NSView {
    /// Every accessibility label reachable below this view.
    @MainActor func accessibilityChildrenDeep() -> Set<String> {
        var labels = Set<String>()
        func walk(_ object: NSObject) {
            let sel = NSSelectorFromString("accessibilityLabel")
            if object.responds(to: sel), let label = object.perform(sel)?.takeUnretainedValue() as? String, !label.isEmpty { labels.insert(label) }
            let kids = NSSelectorFromString("accessibilityChildren")
            if object.responds(to: kids), let children = object.perform(kids)?.takeUnretainedValue() as? [NSObject] { children.forEach(walk) }
        }
        func views(_ view: NSView) { walk(view); view.subviews.forEach(views) }
        views(self)
        return labels
    }
}
