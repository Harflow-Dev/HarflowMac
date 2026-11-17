import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import SwiftUI
import Testing

// MARK: - WorkflowLibraryHostedTests

/// Owned pane evidence; sizes describe the library pane, not a window with a sidebar.
@MainActor @Suite(.serialized)
struct WorkflowLibraryHostedTests {
    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func givenSavedWorkflows_whenLibraryIsMounted_thenRowsAndExactActionsAreAvailable(appearance: ColorScheme, wide: Bool) async throws {
        // given
        let harness = WorkflowLibraryHostedFixture.make()
        let size = CGSize(width: wide ? 1280 : 1000, height: wide ? 800 : 620)
        let fixture = host(harness.vm, size: size, appearance: appearance)
        defer { harness.vm.didDisappear(); fixture.close() }
        // when
        try await activate(fixture)
        await fixture.settle { fixture.element("Edit implement-review") != nil }
        // then
        #expect(fixture.element("Workflows") != nil)
        let edit = try #require(fixture.element("Edit implement-review"))
        let run = try #require(fixture.element("Run implement-review"))
        #expect(fixture.press(edit)); #expect(fixture.press(run))
        #expect(harness.routing.edits == ["implement-review"])
        #expect(harness.routing.runs == ["implement-review"])
        try await capture(fixture, size: size, appearance: appearance, state: "list")
    }

    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func givenEmptyCatalog_whenLibraryIsMounted_thenApprovedCreationActionsRemainAvailable(appearance: ColorScheme, wide: Bool) async throws {
        // given
        let harness = WorkflowLibraryHostedFixture.make()
        harness.useCase.response = ["workflows": .array([])]
        let size = CGSize(width: wide ? 1280 : 1000, height: wide ? 800 : 620)
        let fixture = host(harness.vm, size: size, appearance: appearance)
        defer { harness.vm.didDisappear(); fixture.close() }
        // when
        try await activate(fixture)
        await fixture.settle { fixture.element("No workflows yet") != nil }
        // then
        #expect(fixture.press(try #require(fixture.element("New workflow"))))
        #expect(fixture.press(try #require(fixture.element("Describe one to an agent"))))
        #expect(harness.routing.creations == [false, true])
        try await capture(fixture, size: size, appearance: appearance, state: "empty")
    }

    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func givenPendingCatalog_whenLibraryIsMounted_thenLoadingNeverClaimsEmpty(appearance: ColorScheme, wide: Bool) async throws {
        // given
        let harness = WorkflowLibraryHostedFixture.make()
        harness.useCase.suspended = true
        let size = CGSize(width: wide ? 1280 : 1000, height: wide ? 800 : 620)
        let fixture = host(harness.vm, size: size, appearance: appearance)
        defer { harness.vm.didDisappear(); harness.useCase.finish(); fixture.close() }
        // when
        try await activate(fixture)
        await fixture.settle { fixture.element("Loading workflows") != nil }
        // then
        #expect(fixture.element("No workflows yet") == nil)
        try await capture(fixture, size: size, appearance: appearance, state: "loading")
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenLongCatalogAtMinimumPaneWidth_whenMounted_thenActionsFitAndRowsScroll(appearance: ColorScheme) async throws {
        // given
        let harness = WorkflowLibraryHostedFixture.make(long: true)
        let size = CGSize(width: 720, height: 620)
        let fixture = host(harness.vm, size: size, appearance: appearance)
        defer { harness.vm.didDisappear(); fixture.close() }
        // when
        try await activate(fixture)
        await fixture.settle { harness.vm.presentation.rows.count == 30 }
        // then
        let row = try #require(harness.vm.presentation.rows.first)
        for label in ["Edit " + row.name, "Run " + row.name] {
            let element = try #require(fixture.element(label))
            let frame = try #require(fixture.frame(element))
            #expect(frame.minX >= -1 && frame.maxX <= size.width + 1)
        }
        #expect(fixture.descendants.compactMap { $0 as? NSScrollView }.contains {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        })
        try await capture(fixture, size: size, appearance: appearance, state: "long-scroll")
    }

    func host(_ vm: WorkflowLibraryVM, size: CGSize, appearance: ColorScheme) -> RedesignHost {
        RedesignHost(WorkflowLibraryView(vm)
.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor))
            .preferredColorScheme(appearance)
.environment(\.hfReduceMotionOverride, true), size: size, appearance: appearance)
    }

    func activate(_ fixture: RedesignHost) async throws {
        NSApp.activate(ignoringOtherApps: true)
        fixture.window.makeKeyAndOrderFront(nil)
        await waitUntil(timeout: 5) { NSApp.isActive && fixture.window.isKeyWindow }
        try #require(NSApp.isActive && fixture.window.isKeyWindow)
    }

    private func capture(_ fixture: RedesignHost, size: CGSize, appearance: ColorScheme, state: String) async throws {
        let actualSize = fixture.window.contentLayoutRect.size
        try #require(abs(actualSize.width - size.width) <= 1)
        try #require(abs(actualSize.height - size.height) <= 1)
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_WORKFLOW_LIBRARY_CAPTURE_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scheme = appearance == .light ? "light" : "dark"
        let name = "workflow-library-after-\(state)-\(scheme)-\(Int(size.width))x\(Int(size.height))"
        try await M04NativeWindowEvidence.record(window: fixture.window, name: name, directory: directory)
    }
}
