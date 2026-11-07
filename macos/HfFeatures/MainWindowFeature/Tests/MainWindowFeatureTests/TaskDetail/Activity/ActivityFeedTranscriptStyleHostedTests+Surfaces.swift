import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - ActivityFeedTranscriptStyleHostedTests + surfaces

/// The task screen's other surfaces: the loading skeleton and the "not in harflow's records" branch take the page
/// token in the transcript style, and the style's pill, code and rule colours are the transcript ones.
extension ActivityFeedTranscriptStyleHostedTests {
    private static let skeletonHeader = TaskLoadingHeader(title: "Fix the flaky slot test", repoName: "slots")

    @Test(arguments: [false, true])
    func givenLoadingSkeleton_whenRendered_thenTheTranscriptBackgroundIsThePageTokenAndTheStandardOneIsNot(dark: Bool) async throws {
        // given — the token rendered through the same pipeline is the reference (see the pane background test).
        let reference = try await marginPixel(of: AnyView(TaskScreenStyle.Colors.pageBackground.color), dark: dark)
        // when
        let transcript = try await marginPixel(of: Self.skeleton(.transcript), dark: dark)
        let standard = try await marginPixel(of: Self.skeleton(.standard), dark: dark)
        // then
        #expect(Self.close(transcript, reference), "transcript skeleton pixel \(transcript), want the page token \(reference)")
        #expect(!Self.close(standard, reference), "standard skeleton pixel \(standard) is the page token \(reference)")
    }

    @Test(arguments: [false, true])
    func givenTaskMissingFromRecords_whenRendered_thenTheTranscriptBackgroundIsThePageTokenAndTheStandardOneIsNot(dark: Bool) async throws {
        // given
        let reference = try await marginPixel(of: AnyView(TaskScreenStyle.Colors.pageBackground.color), dark: dark)
        func missing(_ style: ActivityFeedStyle) -> AnyView {
            let mock = TaskDetailViewModelMock()
            mock.task = nil
            mock.hasListed = true
            return AnyView(TaskDetailView(mock, transcriptStyle: style).environment(\.hfReduceMotionOverride, true))
        }
        // when
        let transcript = try await marginPixel(of: missing(.transcript), dark: dark)
        let standard = try await marginPixel(of: missing(.standard), dark: dark)
        // then
        #expect(Self.close(transcript, reference), "transcript pixel \(transcript), want the page token \(reference)")
        #expect(!Self.close(standard, reference), "standard pixel \(standard) is the page token \(reference)")
    }

    @Test func givenFeedStyles_whenReadingPillCodeAndRuleColours_thenOnlyTheTranscriptUsesTheTokens() {
        // given / when / then
        let sunken = TaskScreenStyle.Colors.surfaceSunken.color
        #expect(ActivityFeedStyle.transcript.pillFill == sunken)
        #expect(ActivityFeedStyle.transcript.codeFill == sunken)
        #expect(ActivityFeedStyle.transcript.ruleColor == TaskScreenStyle.Colors.border.color)
        #expect(ActivityFeedStyle.standard.pillFill == Color.pillFill)
        #expect(ActivityFeedStyle.standard.codeFill == Color.codeFill)
        #expect(ActivityFeedStyle.standard.ruleColor == Color.hairline)
        #expect(ActivityFeedStyle.standard.pillFill != ActivityFeedStyle.transcript.pillFill)
        #expect(ActivityFeedStyle.standard.codeFill != ActivityFeedStyle.transcript.codeFill)
        #expect(ActivityFeedStyle.standard.ruleColor != ActivityFeedStyle.transcript.ruleColor)
    }

    @Test(arguments: [false, true])
    func givenSkeleton_whenCaptureDirectorySet_thenTheLoadingSkeletonIsCapturedAt1280x800(dark: Bool) async throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M04_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // given
        _ = NSApplication.shared
        let size = NSSize(width: 1280, height: 800)
        let root = Self.skeleton(.transcript).preferredColorScheme(dark ? .dark : .light)
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
        // when
        await waitUntil(timeout: 8) {
            controller.view.layoutSubtreeIfNeeded()
            controller.view.displayIfNeeded()
            return NSApp.isActive && window.isKeyWindow
        }
        await DisplayFrames.waitForPresentedFrame()
        // then
        let name = "m05-loading-skeleton-\(dark ? "dark" : "light")-1280x800"
        let host = controller.view
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + "-host-bitmap.png"))
        try await M04NativeWindowEvidence.record(window: window, name: name, directory: directory)
    }

    // MARK: Helpers

    private static func skeleton(_ style: ActivityFeedStyle) -> AnyView {
        AnyView(NavigationStack { TaskLoadingSkeleton(header: skeletonHeader, style: style) }
            .environment(\.hfReduceMotionOverride, true))
    }

    private static func close(_ lhs: [Int], _ rhs: [Int]) -> Bool { zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 } }

    /// The RGB (0 ... 255) of one point in the left margin of a 1400 x 800 window rendering `view`.
    private func marginPixel(of view: AnyView, dark: Bool) async throws -> [Int] {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: AnyView(view.preferredColorScheme(dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1400, height: 800),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        window.orderFront(nil)
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await DisplayFrames.waitForPresentedFrame()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = CGFloat(bitmap.pixelsWide) / host.bounds.width
        let color = try #require(bitmap.colorAt(x: Int(12 * scale), y: Int(400 * scale))?.usingColorSpace(.deviceRGB))
        return [color.redComponent, color.greenComponent, color.blueComponent].map { Int(($0 * 255).rounded()) }
    }
}
