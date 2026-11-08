import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskPaneSummaryEntryCaptureHostedTests

/// Optional review captures (`HARFLOW_M05_G1B_CAPTURE_DIR`) of the standalone task screen over preview models, light
/// and dark: the done state with and without the Summary entry, and the Events tab with the usage group expanded in
/// both states. They are evidence for separate visual review and assert only that the owned window rendered the pane.
@MainActor @Suite(.serialized) struct TaskPaneSummaryEntryCaptureHostedTests {
    enum Capture: String, CaseIterable, CustomTestStringConvertible {
        case doneWithEntry = "done-with-entry"
        case doneWithoutEntry = "done-without-entry"
        case usageWithEntry = "usage-with-entry"
        case usageWithoutEntry = "usage-without-entry"
        var testDescription: String { rawValue }

        var entry: Bool { self == .doneWithEntry || self == .usageWithEntry }
        var usage: Bool { self == .usageWithEntry || self == .usageWithoutEntry }
    }

    private func store(for capture: Capture) -> TaskPaneStateStore {
        let store = TaskPaneStateStore()
        let id = "conv"
        if capture.usage {
            store.setOpenChoice(.open, for: id)
            store.setSelectedTab(.events, for: id)
            store.setExpandedGroups([.usage], for: id)
        } else {
            store.setOpenChoice(.closed, for: id)
        }
        return store
    }

    @Test(arguments: Capture.allCases, [false, true])
    func givenTheDoneState_whenCaptureDirectorySet_thenTheScreenIsCaptured(capture: Capture, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_G1B_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // given
        _ = NSApplication.shared
        let size = NSSize(width: 1280, height: 800)
        let detail = PaneMocks.standalone(SummaryEntryPaneMocks.done(entry: capture.entry), store: store(for: capture))
        let root = NavigationStack { detail }
            .preferredColorScheme(dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true)
        let controller = NSHostingController(rootView: root)
        controller.sceneBridgingOptions = .all
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.orderFront(nil)
        window.makeKey()
        defer { window.contentViewController = nil; window.close() }
        let host = controller.view
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

        // then
        let name = "m05-g1b-\(capture.rawValue)-\(dark ? "dark" : "light")-1280x800"
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }
}
