import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskChangesTextCaptureHostedTests

/// Optional review captures (`HARFLOW_M05_G2B_CAPTURE_DIR`) of the Changes tab's second half over preview models, light and
/// dark: a diff, a working-tree diff, bytes that are not UTF-8, a truncated patch, a hostile diff, a row without text, the
/// failure notes and the turn bar. They are evidence for separate visual review and assert only that the owned window rendered.
@MainActor @Suite(.serialized) struct TaskChangesTextCaptureHostedTests {
    enum Capture: String, CaseIterable, CustomTestStringConvertible {
        case diff, workingTree = "working-tree", bytes, truncated, hostile, noText = "no-text", reload, retry, turns
        var testDescription: String { rawValue }
    }

    private func mock(for capture: Capture) throws -> TaskDetailViewModelMock {
        switch capture {
        case .diff: return try ChangesTextMocks.mock()
        case .workingTree: return try ChangesTextMocks.mock(working: true)
        case .bytes:
            return try ChangesTextMocks.mock(bytes: Data("@@ -1 +1 @@\n-caf".utf8) + Data([0xE9, 0xFF]) + Data("\n+cafe\n".utf8))
        case .truncated: return try ChangesTextMocks.mock(state: "truncated", reason: "file_limit")
        case .hostile:
            return try ChangesTextMocks.mock(diff: "@@ -1 +1 @@\n-a\u{202E}b\n+tab\there\u{200B}\r\n+\\u{41}\n--- not a header\n")
        case .noText:
            let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
            mock.changesDiff = .none
            return mock
        case .reload:
            let mock = ChangesPaneMocks.mock(try ChangesJSON.availableListing())
            mock.changesDiff = .failure(ChangesTextMocks.header, TaskChangesDiffBuilder.Failure.reload.note)
            return mock
        case .retry:
            let mock = try ChangesTextMocks.mock()
            mock.changesDiff = .failure(ChangesTextMocks.header, TaskChangesDiffBuilder.Failure.clientBound.note)
            return mock
        case .turns:
            let mock = try ChangesTextMocks.mock()
            mock.changesTurns = ChangesTextMocks.turns(selected: "bbbbbbbb-0002")
            return mock
        }
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    @Test(arguments: Capture.allCases, [false, true])
    func givenTextState_whenCaptureDirectorySet_thenTheTabIsCaptured(capture: Capture, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_G2B_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // given
        _ = NSApplication.shared
        let size = NSSize(width: 1280, height: 900)
        let detail = PaneMocks.standalone(try mock(for: capture), store: ChangesPaneMocks.store())
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
        let name = "m05-g2b-\(capture.rawValue)-\(dark ? "dark" : "light")-1280x900"
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }

    @Test(arguments: [false, true])
    func givenTheLastLongDiffLine_whenScrolledIntoTheOuterPane_thenBothViewportSizesAreCaptured(dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_G2B_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let patch = "@@ -1 +1 @@\n+" + String(repeating: "x", count: 63_900)
        for size in [NSSize(width: 1000, height: 620), NSSize(width: 1280, height: 800)] {
            let longLine = try ChangesTextMocks.mock(state: "truncated", reason: "file_limit", bytes: Data(patch.utf8))
            let detail = PaneMocks.standalone(longLine, store: ChangesPaneMocks.store())
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
            var diffView: NSTextView?
            await waitUntil(timeout: 15) {
                host.layoutSubtreeIfNeeded()
                diffView = allViews(host).compactMap { $0 as? NSTextView }.first { $0.accessibilityLabel() == "Diff of src/app.py" }
                return diffView?.string.utf8.count ?? 0 >= 63_000
            }
            let view = try #require(diffView)
            let last = (view.string as NSString).length - 1
            view.scrollRangeToVisible(NSRange(location: last, length: 1))
            var scrollPasses = 0
            await waitUntil(timeout: 8) {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                host.layoutSubtreeIfNeeded()
                host.displayIfNeeded()
                scrollPasses += 1
                return scrollPasses >= 60
            }
            await DisplayFrames.waitForPresentedFrame()
            let name = "m05-g2b-inline-bottom-\(dark ? "dark" : "light")-\(Int(size.width))x\(Int(size.height))"
            try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
        }
    }
}
