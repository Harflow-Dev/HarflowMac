import AppKit
import MonitorCore
import PbTestUtilities
@testable import PbUI
import SwiftUI
import Testing

// MARK: - MaterialRowInkTests

/// The menu-bar material needs a darker metadata ink than the shared rows use on ordinary
/// surfaces. These tests exercise the public view input at the rendered boundary: the default is
/// byte-compatible, the override is scoped to ordinary menu-bar rows, and native emphasis/sidebar
/// presentation retains its own contrast contract.
@MainActor @Suite(.serialized) struct MaterialRowInkTests {
    @Test(arguments: [false, true])
    func givenDefaultTaskRow_whenMetadataInkIsOmittedOrExplicitlyNil_thenRenderingAndCopyRemainStandard(
        dark: Bool
    ) async throws {
        // given
        let row = taskRow()
        // when
        let omitted = try await render(taskFixture(TaskRow(model: row), dark: dark), dark: dark)
        let explicitNil = try await render(
            taskFixture(TaskRow(model: row, metadataForeground: nil), dark: dark), dark: dark
        )

        // then
        #expect(omitted == explicitNil)
        #expect(!omitted.isEmpty)
        #expect(row.subtitle == "polybridge · Claude")
        #expect(row.detailLabel == "detail line")
        #expect(row.ageText == "3h")
    }

    @Test(arguments: [false, true])
    func givenNormalTaskRow_whenMetadataInkIsOverridden_thenOnlyRenderedInkChanges(
        dark: Bool
    ) async throws {
        // given
        let row = taskRow()
        // when
        let standard = try await render(taskFixture(TaskRow(model: row), dark: dark), dark: dark)
        let overridden = try await render(
            taskFixture(TaskRow(model: row, metadataForeground: .primaryText), dark: dark), dark: dark
        )

        // then — the stable title/status copy remains present while the metadata pixels change.
        #expect(standard != overridden)
        #expect(row.title == "Review the release")
        #expect(row.subtitle == "polybridge · Claude")
        #expect(row.detailLabel == "detail line")
        #expect(row.ageText == "3h")
    }

    @Test(arguments: [false, true])
    func givenSidebarTaskRow_whenMetadataInkIsOverridden_thenSidebarRenderingIgnoresIt(
        dark: Bool
    ) async throws {
        // given
        let row = taskRow()
        // when
        let standard = try await render(
            taskFixture(TaskRow(model: row, sidebarAppearance: SidebarRowAppearance()), dark: dark), dark: dark
        )
        let overridden = try await render(
            taskFixture(
                TaskRow(model: row, sidebarAppearance: SidebarRowAppearance(), metadataForeground: .primaryText),
                dark: dark
            ), dark: dark
        )

        // then
        #expect(standard == overridden)
    }

    @Test(arguments: [false, true])
    func givenEmphasizedTaskRow_whenMetadataInkIsOverridden_thenOnAccentRenderingWins(
        dark: Bool
    ) async throws {
        // given
        let row = taskRow()
        // when
        let standard = try await render(
            taskFixture(TaskRow(model: row).environment(\.backgroundProminence, .increased), dark: dark),
            dark: dark
        )
        let overridden = try await render(
            taskFixture(
                TaskRow(model: row, metadataForeground: .primaryText)
                    .environment(\.backgroundProminence, .increased),
                dark: dark
            ), dark: dark
        )

        // then
        #expect(standard == overridden)
    }

    @Test(arguments: [false, true])
    func givenGroupRow_whenMetadataInkIsOmittedOrOverridden_thenOnlyOrdinaryRowsHonorTheOverride(
        dark: Bool
    ) async throws {
        // given
        let group = parallelGroup()
        // when
        let standard = try await render(groupFixture(GroupRow(group: group), dark: dark), dark: dark)
        let explicitNil = try await render(
            groupFixture(GroupRow(group: group, metadataForeground: nil), dark: dark), dark: dark
        )
        let overridden = try await render(
            groupFixture(GroupRow(group: group, metadataForeground: .primaryText), dark: dark), dark: dark
        )
        let sidebar = try await render(
            groupFixture(GroupRow(group: group, sidebarAppearance: SidebarRowAppearance()), dark: dark), dark: dark
        )
        let sidebarOverridden = try await render(
            groupFixture(
                GroupRow(
                    group: group, sidebarAppearance: SidebarRowAppearance(), metadataForeground: .primaryText
                ), dark: dark
            ), dark: dark
        )
        let emphasized = try await render(
            groupFixture(
                GroupRow(group: group).environment(\.backgroundProminence, .increased), dark: dark
            ), dark: dark
        )
        let emphasizedOverridden = try await render(
            groupFixture(
                GroupRow(group: group, metadataForeground: .primaryText)
                    .environment(\.backgroundProminence, .increased), dark: dark
            ), dark: dark
        )

        // then
        #expect(standard == explicitNil)
        #expect(standard != overridden)
        #expect(sidebar == sidebarOverridden)
        #expect(emphasized == emphasizedOverridden)
    }

    @Test func givenRowInkInputs_whenConstructed_thenTheyDoNotChangeModelCopyOrIdentityFields() {
        // given
        let row = taskRow()
        // when / then
        #expect(row.id == "material-task")
        #expect(row.backend == "claude")
        #expect(row.title == "Review the release")
        #expect(row.subtitle == "polybridge · Claude")
        #expect(row.detailLabel == "detail line")
        #expect(row.ageText == "3h")
    }

    private func taskRow() -> TaskRowModel {
        TaskRowModel(
            id: "material-task", backend: "claude", title: "Review the release", status: .completed,
            repoName: "polybridge", ageText: "3h", detailLabel: "detail line"
        )
    }

    private func parallelGroup() -> ParallelGroup {
        let tasks = [
            TaskInfo(.object([
                "task_id": .string("material-running"), "backend": .string("claude"),
                "status": .string("running"), "group": .string("material-group")
            ]))!,
            TaskInfo(.object([
                "task_id": .string("material-finished"), "backend": .string("codex"),
                "status": .string("completed"), "group": .string("material-group")
            ]))!
        ]
        return Lineage.sections(tasks).parallel.first!
    }

    private func taskFixture(_ view: some View, dark: Bool) -> some View {
        view
            .frame(width: 420, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.spacing12)
            .background(Color.windowBG)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.pbReduceMotionOverride, true)
    }

    private func groupFixture(_ view: some View, dark: Bool) -> some View {
        view
            .frame(width: 420, alignment: .leading)
            .padding(.horizontal, PbRadius.Metrics.spacing12)
            .background(Color.windowBG)
            .environment(\.colorScheme, dark ? .dark : .light)
            .environment(\.pbReduceMotionOverride, true)
    }

    private func render(_ view: some View, dark: Bool) async throws -> Data {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 444, height: 90), styleMask: [.borderless],
            backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.layoutSubtreeIfNeeded()
        await DisplayFrames.waitForPresentedFrame()
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: 888, pixelsHigh: 180, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: 444, height: 90)
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }
}
