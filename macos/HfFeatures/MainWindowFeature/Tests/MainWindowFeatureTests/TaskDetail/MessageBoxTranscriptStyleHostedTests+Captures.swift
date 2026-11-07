import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - MessageBoxTranscriptStyleHostedTests + captures

/// Optional review captures (`HARFLOW_M04_CAPTURE_DIR`) of the task detail's composer states, over a preview VM.
extension MessageBoxTranscriptStyleHostedTests {
    @Test(arguments: ["composer-empty", "composer-locked", "composer-multiline"], [false, true])
    func givenComposerState_whenCaptureDirectorySet_thenTheTaskDetailIsCapturedAt1280x800(state: String, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // given
        _ = NSApplication.shared
        let size = NSSize(width: 1280, height: 800)
        let mock = TaskDetailViewModelMock.finished()
        mock.timelineModel = ActivityFeedTranscriptStyleHostedTests.timelineModel([
            ActivityFixture.text(1, "The retry path already re-checks the count, so no change was needed there.",
                                 task: ActivityFeedTranscriptStyleHostedTests.taskID)
        ])
        if state == "composer-locked" { mock.messageBoxModel = Self.lockedModel }
        let root = NavigationStack { TaskDetailView(mock, transcriptStyle: .transcript) }
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
        NSApp.activate(ignoringOtherApps: true)
        defer { window.contentViewController = nil; window.close() }
        let host = controller.view
        await waitUntil(timeout: 8) {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            return NSApp.isActive && window.isKeyWindow
        }
        if state == "composer-multiline" {
            func field() -> NSTextField? { Self.allViews(host).compactMap { $0 as? NSTextField }.first { $0.isEditable } }
            await waitUntil(timeout: 8) { field() != nil }
            let target = try #require(field())
            _ = window.makeFirstResponder(target)
            let text = "Please also check the retry path.\nThen re-run the slot tests twice.\nReport anything that is still flaky."
            target.stringValue = text
            target.currentEditor()?.string = text
            target.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: target))
        }
        var passes = 0
        await waitUntil(timeout: 8) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            passes += 1
            return passes >= 40
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let name = "m05-\(state)-\(dark ? "dark" : "light")-1280x800"
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }

    static func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}
