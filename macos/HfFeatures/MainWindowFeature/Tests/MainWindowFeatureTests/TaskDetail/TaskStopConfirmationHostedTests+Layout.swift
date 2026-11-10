import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - TaskStopConfirmationHostedTests + Layout

extension TaskStopConfirmationHostedTests {
    @Test(arguments: [false, true], [false, true])
    func givenPlainOrLongLineage_whenNativeSheetOpens_thenActionsStayVisibleAndOptionalCaptureIsWritten(dark: Bool, longList: Bool) async throws {
        // given
        let titles = longList ? (1 ... 30).map { "Earlier task \($0) with a long title that wraps over several lines in this confirmation" } : []
        let page = RedesignHost(StopLayoutHarness(titles: titles).preferredColorScheme(dark ? .dark : .light),
                                size: CGSize(width: 960, height: 600), appearance: dark ? .dark : .light)
        defer { page.close() }
        await page.settle { page.element("Open confirmation") != nil }
        // when
        #expect(page.press(try #require(page.element("Open confirmation"))))
        await page.settle { page.window.attachedSheet != nil }
        let sheet = try #require(page.window.attachedSheet)
        let root = try #require(sheet.contentView)
        func element(_ label: String) -> NSObject? { page.elements(in: root).first { page.matches($0, label) } }
        await page.settle { element("Keep running") != nil && root.bounds.height > 100 }
        var passes = 0
        await page.settle { passes += 1; root.layoutSubtreeIfNeeded(); return passes >= 15 }
        // then
        #expect(abs(root.bounds.width - TaskScreenStyle.Dialog.width) <= 1)
        #expect(root.bounds.height <= 600)
        #expect(root.bounds.height > 180)
        let stop = try #require(element("Stop task"))
        let stopFrame = sheet.convertFromScreen(page.window.convertToScreen(try #require(page.frame(stop))))
        #expect(stopFrame.minY >= 0)
        #expect(stopFrame.maxY <= sheet.frame.height)
        let scrolls = allViews(root).compactMap { $0 as? NSScrollView }
        if longList {
            #expect(scrolls.contains { ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height + 100 })
        } else {
            #expect(element("Won't be stopped by this") == nil)
        }
        if let output = ProcessInfo.processInfo.environment["HARFLOW_M05_STOP_CAPTURE_DIR"], !output.isEmpty {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            await DisplayFrames.waitForPresentedFrame()
            root.layoutSubtreeIfNeeded()
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            root.cacheDisplay(in: root.bounds, to: bitmap)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: directory.appendingPathComponent("stop-\(longList ? "long-lineage" : "plain")-\(dark ? "dark" : "light").png"))
        }
        #expect(page.press(try #require(element("Keep running"))))
        await page.settle { page.window.attachedSheet == nil }
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }
}

// MARK: - StopLayoutHarness

private struct StopLayoutHarness: View {
    let titles: [String]
    @State private var request: TaskStopConfirmation?
    var body: some View {
        Button("Open confirmation") {
            request = .init(conversationID: "conversation", taskID: "task", notStoppedTitles: titles, confirm: {})
        }
        .sheet(item: $request) { confirmation in
            TaskStopConfirmationView(confirmation: confirmation, onConfirm: {})
        }
    }
}
