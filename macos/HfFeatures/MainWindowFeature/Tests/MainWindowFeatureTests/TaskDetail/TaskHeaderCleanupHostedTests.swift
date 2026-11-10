import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - TaskHeaderCleanupHostedTests

/// Standalone header removal preserves durable feedback and provenance while legacy mounts retain their header.
@MainActor @Suite(.serialized) struct TaskHeaderCleanupHostedTests {
    private let provenance = "Started by agent parent01. Results return to the parent agent."

    private func mount(_ mock: TaskDetailViewModelMock, open: Bool = false, width: CGFloat = 1280, dark: Bool = false) async -> PaneHost {
        let store = TaskPaneStateStore()
        store.setOpenChoice(open ? .open : .closed, for: "conv")
        store.setSelectedTab(.events, for: "conv")
        store.setExpandedGroups([.task], for: "conv")
        let host = PaneHost(PaneMocks.standalone(mock, store: store), size: CGSize(width: width, height: 900), dark: dark)
        await host.page.settle { host.columnWidth != nil && (!open || host.hasPane) }
        return host
    }

    @Test(arguments: [false, true])
    func givenStandaloneTaskWithLegacyHeaderFacts_whenMounted_thenNoLegacyHeaderControlsOrBannersRemain(dark: Bool) async throws {
        // given
        let mock = PaneMocks.continuity(notices: ["A recorded notice"])
        mock.ancestorCrumbs = [AncestorCrumb(id: "parent01", title: "Parent breadcrumb")]
        mock.takenOverBannerText = "Taken over in Terminal"
        mock.spawnedByBannerText = provenance

        // when
        let host = await mount(mock, dark: dark)
        defer { host.close() }

        // then
        for label in ["Parent breadcrumb", "Repository \(Format.repoName(mock.task!.repoPath))", "Show supervision details",
                      "Server restarted · Task still running",
                      "Taken over in Terminal", provenance] {
            #expect(host.page.element(label) == nil, "legacy header still exposes \(label)")
        }
        #expect(host.page.element("Sub-task started by another agent") != nil)
        try capture(host, name: "header-cleanup-closed-\(dark ? "dark" : "light")")
    }

    @Test func givenStandaloneTaskWithoutFeedback_whenMounted_thenOriginalRequestStartsAtTheColumnTop() async throws {
        // given / when
        let host = await mount(PaneMocks.running())
        defer { host.close() }

        // then — the request's own 16 point inset remains, with no reserved legacy header height.
        let request = try #require(host.page.element("Original request"))
        let frame = try #require(host.page.frame(request))
        let root = host.page.host.convert(host.page.host.bounds, to: nil)
        #expect(root.maxY - frame.maxY < 42, "request top inset \(root.maxY - frame.maxY)")
        #expect(host.page.element("Repository repo") == nil)
        #expect(host.page.element("Sub-task started by another agent") == nil)
    }

    @Test func givenDurableOutcome_whenStandaloneMounted_thenItsExactTextRemainsVisible() async throws {
        // given
        let mock = PaneMocks.running()
        let message = "Queued verbatim · awaiting the active response."
        mock.outcomeMessage = message

        // when
        let host = await mount(mock)
        defer { host.close() }

        // then
        let feedback = try #require(host.page.element(message))
        #expect(host.page.frame(feedback)?.height ?? 0 > 0)
        #expect(host.page.element("Original request") != nil)
    }

    @Test(arguments: [1000, 1600] as [CGFloat])
    func givenSubtaskProvenance_whenStandaloneMounted_thenShortLineIsInsideTranscriptReadingColumnAndFullFactRemains(width: CGFloat) async throws {
        // given — task metadata intentionally does not carry spawned_by: the VM owns first-member provenance.
        let mock = PaneMocks.running()
        mock.spawnedByBannerText = provenance

        // when
        let host = await mount(mock, open: true, width: width)
        defer { host.close() }
        await host.page.settle { host.page.element(provenance) != nil }

        // then
        let short = try #require(host.page.element("Sub-task started by another agent"))
        let frame = try #require(host.page.frame(short))
        let table = try #require(ActivityFeedTranscriptStyleHostedTests.tables(host.page.host).first)
        let scroll = try #require(table.enclosingScrollView)
        let column = scroll.convert(scroll.bounds, to: nil)
        #expect(frame.minX >= column.minX + 30)
        #expect(frame.maxX <= column.maxX - 30)
        #expect(host.page.element(provenance) != nil)
        #expect(host.headerValue("Task") == "Expanded")
        try capture(host, name: "header-cleanup-provenance-\(Int(width))")
    }

    @Test(arguments: [true, false])
    func givenTakenOverTask_whenTaskFactsExpanded_thenEngineNoteWinsAndMissingNoteUsesExistingBannerFallback(hasNote: Bool) async {
        // given
        let mock = PaneMocks.running()
        var raw = mock.task!.raw
        raw["taken_over"] = .bool(true)
        if hasNote { raw["taken_over_note"] = .string("Engine takeover note") }
        mock.task = TaskInfo(.object(raw))!
        mock.takenOverBannerText = "The session is now running in your terminal."
        let expected = hasNote ? "Engine takeover note" : mock.takenOverBannerText!

        // when
        let host = await mount(mock, open: true)
        defer { host.close() }
        await host.page.settle { host.page.element(expected) != nil }

        // then
        #expect(host.page.element(expected) != nil)
        if hasNote { #expect(host.page.element(mock.takenOverBannerText!) == nil) }
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenLegacyMount_whenMounted_thenMetadataBreadcrumbAndFullBannersRemain(chrome: TaskDetailChrome) async {
        // given
        let mock = PaneMocks.continuity(notices: ["A recorded notice"])
        mock.ancestorCrumbs = [AncestorCrumb(id: "parent01", title: "Parent breadcrumb")]
        mock.spawnedByBannerText = provenance
        mock.takenOverBannerText = "Taken over in Terminal"
        mock.outcomeMessage = "Preserved outcome"

        // when
        let host = PaneHost(TaskDetailView(mock, chrome: chrome, transcriptStyle: .standard)
            .environment(\.hfReduceMotionOverride, true), size: CGSize(width: 1280, height: 1000))
        defer { host.close() }
        let repositoryLabel = "Repository \(Format.repoName(mock.task!.repoPath))"
        await host.page.settle { host.page.element(repositoryLabel) != nil }

        // then
        for label in [repositoryLabel, "Parent breadcrumb", provenance, "Taken over in Terminal", "Preserved outcome", "Show supervision details"] {
            #expect(host.page.element(label) != nil, "legacy mount lost \(label)")
        }
    }

    private func capture(_ host: PaneHost, name: String) throws {
        guard let output = ProcessInfo.processInfo.environment["HARFLOW_M05_HEADER_CAPTURE_DIR"], !output.isEmpty else { return }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        host.page.host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.page.host.bitmapImageRepForCachingDisplay(in: host.page.host.bounds))
        host.page.host.cacheDisplay(in: host.page.host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent(name + ".png"))
    }

}
