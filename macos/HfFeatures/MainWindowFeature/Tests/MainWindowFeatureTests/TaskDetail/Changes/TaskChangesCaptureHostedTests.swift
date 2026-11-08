import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskChangesCaptureHostedTests

/// Optional review captures (`HARFLOW_M05_G2A_CAPTURE_DIR`) of the standalone Changes tab over preview models, light and dark:
/// loading, running, settling, capped, zero, populated, incomplete, multiple repositories, unsupported and error. They are
/// evidence for separate visual review and assert only that the owned window rendered.
@MainActor @Suite(.serialized) struct TaskChangesCaptureHostedTests {
    enum Capture: String, CaseIterable, CustomTestStringConvertible {
        case loading, running, settling, capped, zero, populated, incomplete, multi, unsupported, error
        var testDescription: String { rawValue }
    }

    private func mock(for capture: Capture) throws -> TaskDetailViewModelMock {
        switch capture {
        case .loading: return PaneMocks.done(exit: 0)
        case .running: return ChangesPaneMocks.mock(try ChangesJSON.pendingRunning())
        case .settling: return ChangesPaneMocks.mock(try ChangesJSON.pendingSettling())
        case .capped:
            let mock = PaneMocks.done(exit: 0)
            mock.changesPresentation = .settlingCapped
            return mock
        case .zero: return ChangesPaneMocks.mock(try ChangesJSON.zeroRows())
        case .populated: return ChangesPaneMocks.mock(try ChangesJSON.availableListing())
        case .incomplete: return ChangesPaneMocks.mock(try ChangesJSON.incomplete())
        case .multi: return ChangesPaneMocks.mock(try ChangesPaneMocks.multiSnapshot())
        case .unsupported:
            let error = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-changes", detail: "")
            return ChangesPaneMocks.mock(TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.failed(error))))
        case .error:
            return ChangesPaneMocks.mock(TaskChangesPresentationBuilder.build(taskID: "t1", outcome: .failure(.clientBound(.deadline))))
        }
    }

    @Test(arguments: Capture.allCases, [false, true])
    func givenChangesState_whenCaptureDirectorySet_thenTheTabIsCaptured(capture: Capture, dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_G2A_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // given
        _ = NSApplication.shared
        let size = NSSize(width: 1280, height: 800)
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
        let name = "m05-g2a-\(capture.rawValue)-\(dark ? "dark" : "light")-1280x800"
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }
}
