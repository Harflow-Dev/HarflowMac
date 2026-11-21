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
    private struct CompactCaptureRequest {
        let mock: TaskDetailViewModelMock
        let paneCapture: Capture
        let subject: HostedCaptureEvidence.Subject
        let scrollToResultEnd: Bool
    }

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

    private func keepActive(_ window: NSWindow, host: NSView) {
        if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
        if !window.isVisible || !window.isKeyWindow { window.makeKeyAndOrderFront(nil) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    private func requireForeground(_ window: NSWindow, host: NSView) async throws {
        await waitUntil(timeout: 15) {
            keepActive(window, host: host)
            return NSApp.isActive && window.isVisible && window.isKeyWindow
        }
        try #require(NSApp.isActive && window.isVisible && window.isKeyWindow,
                     "Capture foreground unavailable: active=\(NSApp.isActive), visible=\(window.isVisible), key=\(window.isKeyWindow)")
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
        try await requireForeground(window, host: host)
        var passes = 0
        await waitUntil(timeout: 8) {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            keepActive(window, host: host)
            passes += 1
            return passes >= 60
        }
        await DisplayFrames.waitForPresentedFrame()

        // then
        let name = "m05-g1b-\(capture.rawValue)-\(dark ? "dark" : "light")-1280x800"
        try await requireForeground(window, host: host)
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }

    @Test func givenCompactMinimumCaptureDirectorySet_thenLongResultAndUnavailableUsageAreCaptured() async throws {
        guard let directory = HostedCaptureEvidence.directory("HARFLOW_EVENTS_COMPACT_CAPTURE_DIR") else { return }
        _ = NSApplication.shared
        let designCommit = "5539168eee43429edc2267f2a9402daf5f9a2d15"
        let sizes = [NSSize(width: 1280, height: 800), NSSize(width: 1000, height: 620)]
        for entry in [false, true] {
            for dark in [false, true] {
                for size in sizes {
                    let minimum = size.width == 1000
                    let baseState = entry ? "usage-with-transcript-summary" : "result-and-usage"
                    let baseRoute = entry ? "task/events-usage" : "task/events-result-usage"
                    let state = baseState + (minimum ? "-minimum" : "")
                    let route = baseRoute + (minimum ? "-minimum" : "")
                    let paneCapture: Capture = entry ? .usageWithEntry : .usageWithoutEntry
                    let subject = HostedCaptureEvidence.Subject(
                        suite: "task-events-compact", state: state, dark: dark, size: size,
                        design: .init(route: route, file: "v2/docs/decisions/task-detail-and-workflow-approvals.md", commit: designCommit)
                    )
                    try await captureCompact(.init(mock: SummaryEntryPaneMocks.done(entry: entry), paneCapture: paneCapture,
                                                    subject: subject, scrollToResultEnd: false), directory: directory)
                }
            }
        }

        let longResult = Array(repeating: "The full reported result remains in the expanded Events content.", count: 48).joined(separator: "\n\n")
            + "\n\nCOMPACT_EVENTS_FINAL_RESULT_MARKER"
        for dark in [false, true] {
            let subject = HostedCaptureEvidence.Subject(
                suite: "task-events-compact", state: "result-and-usage-long-minimum", dark: dark,
                size: NSSize(width: 1000, height: 620),
                design: .init(route: "task/events-result-usage-minimum", file: "v2/docs/decisions/task-detail-and-workflow-approvals.md",
                              commit: designCommit)
            )
            try await captureCompact(.init(mock: SummaryEntryPaneMocks.done(entry: false, summaryText: longResult),
                                            paneCapture: .usageWithoutEntry, subject: subject, scrollToResultEnd: true),
                                     directory: directory)
        }

        let unavailableSubject = HostedCaptureEvidence.Subject(
            suite: "task-events-compact", state: "usage-unavailable-minimum", dark: false, size: NSSize(width: 1000, height: 620),
            design: .init(route: "task/events-usage-minimum", file: "v2/docs/decisions/task-detail-and-workflow-approvals.md",
                          commit: designCommit)
        )
        try await captureCompact(.init(mock: SummaryEntryPaneMocks.unavailable(entry: true), paneCapture: .usageWithEntry,
                                        subject: unavailableSubject, scrollToResultEnd: false), directory: directory)
    }

    private func captureCompact(_ request: CompactCaptureRequest, directory: URL) async throws {
        let detail = PaneMocks.standalone(request.mock, store: store(for: request.paneCapture))
        let root = NavigationStack { detail }
            .preferredColorScheme(request.subject.dark ? .dark : .light)
            .environment(\.hfReduceMotionOverride, true)
        let fixture = PaneHost(root, size: request.subject.size, dark: request.subject.dark)
        defer { fixture.close() }
        let host = fixture.page.host

        await fixture.page.settle {
            fixture.hasPane && fixture.header("Reported") != nil && fixture.paneScrollViews().count == 1
        }
        await HostedCaptureEvidence.prepare(fixture.page.window, dark: request.subject.dark)
        await DisplayFrames.waitForPresentedFrame()

        if request.subject.state == "usage-unavailable-minimum" {
            let scroll = try #require(fixture.paneScrollViews().first)
            let copy = try #require(fixture.allElements.first { element in
                ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { key in
                    fixture.string(element, key) == "Reported usage unavailable."
                }
            })
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            #expect(fixture.page.frame(copy).map(viewport.intersects) == true,
                    "The minimum-size unavailable usage capture must show its empty-state copy")
        }

        if request.scrollToResultEnd {
            let scroll = try #require(fixture.paneScrollViews().first)
            let document = try #require(scroll.documentView)
            var maximumOffset: CGFloat = 0
            await fixture.page.settle {
                maximumOffset = max(0, document.bounds.height - scroll.contentView.bounds.height)
                scroll.contentView.scroll(to: NSPoint(x: 0, y: maximumOffset))
                scroll.reflectScrolledClipView(scroll.contentView)
                return abs(scroll.contentView.bounds.origin.y - maximumOffset) <= 2
            }
            await fixture.pump(20)
            let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            let markerFrames = fixture.allElements.compactMap { element -> CGRect? in
                let matchesMarker = ["accessibilityLabel", "accessibilityValue", "accessibilityTitle"].contains { key in
                    fixture.string(element, key)?.contains("COMPACT_EVENTS_FINAL_RESULT_MARKER") == true
                }
                return matchesMarker ? fixture.page.frame(element) : nil
            }
            #expect(!markerFrames.isEmpty, "The long result must expose its final marker to accessibility")
            #expect(markerFrames.contains(where: viewport.intersects), "The minimum-size long-result capture must show its final marker")
            #expect(abs(scroll.contentView.bounds.origin.y - maximumOffset) <= 2,
                    "The result-end capture must retain the outer scroll view's maximum offset")
        }

        try await HostedCaptureEvidence.record(directory: directory, subject: request.subject, window: fixture.page.window, host: host)
    }
}
