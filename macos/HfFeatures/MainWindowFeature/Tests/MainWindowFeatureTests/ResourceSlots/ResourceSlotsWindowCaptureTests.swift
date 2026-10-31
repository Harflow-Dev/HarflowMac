import AppKit
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

extension ActivityFeedApprovalHostedTests {
    @Test func givenCaptureDirectory_whenCapturingResourceSlotStates_thenCaptureProductionWindows() async throws {
        guard let directory = try resourceSlotsCaptureDirectory() else { return }
        let sizes: [(name: String, size: CGSize)] = [
            ("compact", CGSize(width: 1000, height: 620)),
            ("standard", CGSize(width: 1200, height: 820)),
            ("wide", CGSize(width: 1440, height: 900))
        ]
        let states = ["populated", "loading", "empty", "error", "cleanup", "long-titles", "borrowed"]
        for appearance in [ColorScheme.light, .dark] {
            for (state, size) in states.flatMap({ state in sizes.map { (state, $0) } }) {
                let model = CaptureModel(state: state)
                let sidebar = SidebarViewModelMock(searchQuery: "retained history search", selection: .resourceSlots)
                let navigation = NavigationSplitView {
                    SidebarView(sidebar).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
                } detail: {
                    ResourceSlotsView(model)
                }
                .preferredColorScheme(appearance)
                .environment(\.hfReduceMotionOverride, true)
                let fixture = RedesignHost(navigation, size: size.size, appearance: appearance)
                defer { fixture.close() }
                try await resourceSlotsForeground(fixture)
                await fixture.settle { fixture.element("Resource slots") != nil }
                try #require(fixture.element("Resource slots") != nil)
                try #require(fixture.element("Search loaded history") != nil)
                #expect(fixture.element("Search resource slots") == nil)
                if state == "populated" || state == "cleanup" || state == "long-titles" || state == "borrowed" {
                    let groupTitle = state == "long-titles"
                        ? "A deliberately long configured resource name that needs to wrap cleanly at compact window widths"
                        : "sim"
                    await fixture.settle { fixture.element(groupTitle) != nil }
                    try #require(fixture.element(groupTitle) != nil)
                }
                await fixture.settle { fixture.hasStableRenderedFrame }
                try #require(fixture.hasRenderedInk, "Capture must contain actual rendered production content")
                let scheme = appearance == .light ? "light" : "dark"
                let filename = "resource-slots-\(state)-\(size.name)-\(scheme).png"
                try resourceSlotsScreenCapture(fixture.window, to: directory.appendingPathComponent(filename))
            }
        }
    }

    private func resourceSlotsCaptureDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_RESOURCE_SLOTS_CAPTURE_DIR"], !path.isEmpty else { return nil }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resourceSlotsForeground(_ fixture: RedesignHost) async throws {
        NSApp.setActivationPolicy(.regular)
        fixture.window.isOpaque = true
        fixture.window.backgroundColor = .windowBackgroundColor
        fixture.window.center()
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.window.isKeyWindow && NSApp.isActive }
        try #require(fixture.window.isKeyWindow && NSApp.isActive)
    }

    private func resourceSlotsScreenCapture(_ window: NSWindow, to url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-l", String(window.windowNumber), url.path]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
        try #require(!Data(contentsOf: url).isEmpty)
    }

    @Observable @MainActor fileprivate final class CaptureModel: ResourceSlotsViewModel {
        let presentation: ResourceSlotsPresentation
        let expandedResourceIDs: Set<String>
        let expandedBlockerIDs: Set<String> = []
        let readingState = ResourceSlotsReadingState()

        init(state: String) {
            let groupTitle = state == "long-titles"
                ? "A deliberately long configured resource name that needs to wrap cleanly at compact window widths"
                : "sim"
            let holders = state == "borrowed" ? [
                Self.owner("sim/borrowed-a", title: "Borrowed task", status: "Held", detail: "Borrowed; no additional capacity consumed"),
                Self.owner("sim/borrowed-b", title: "Second borrowed task", status: "Release requested", detail: "Reservation remains retained")
            ] : [
                Self.owner("sim/task-hold", title: "Build turn", status: "Held", action: .init(label: "Open task", ownerID: "task-1")),
                Self.owner(
                    "sim/workflow-hold",
                    title: "A deployment run with a deliberately long owner title that wraps across multiple lines",
                    status: "Held", detail: "Workflow run run-1 / attempt-2"
                )
            ]
            let group = ResourceSlotsGroup(
                id: "sim", title: groupTitle,
                capacitySummary: state == "cleanup" ? "2 of 1 capacity · observed holdings exceed capacity" : "2 of 3 capacity in use",
                holderHeading: "Current holders",
                holders: state == "cleanup"
                    ? [Self.owner(
                        "sim/cleanup", title: "Cleanup uncertain", status: "Capacity retained",
                        detail: "Cleanup policy unavailable; capacity remains occupied"
                    )]
                    : holders,
                emptyHolderMessage: state == "empty" ? "No reservations are using this resource." : nil,
                waiterHeading: "Waiting",
                waiters: state == "populated" ? [Self.owner(
                    "sim/waiter", title: "Queued task", status: "Queue position 1",
                    detail: "Waiting for a holder to release capacity", position: "1"
                )]
                    : []
            )
            let qualifiers: [ResourceSlotsQualifier] = state == "error"
                ? [.init(id: "stale", text: "Showing the last successful observations. The latest read failed.", isWarning: true)] : []
            switch state {
            case "loading":
                self.presentation = .init(state: .loading, qualifiers: [])
            case "empty":
                self.presentation = .init(
                    state: .empty(title: "No resource slots", message: "No configured names or active reservations were reported."),
                    qualifiers: []
                )
            case "error":
                self.presentation = .init(
                    state: .ready(summary: "Observed holdings and queued resource entries", groups: [group]),
                    qualifiers: qualifiers
                )
            default:
                self.presentation = .init(state: .ready(summary: "Observed holdings and queued resource entries", groups: [group]), qualifiers: qualifiers)
            }
            self.expandedResourceIDs = ["sim"]
        }

        func didAppear() {}
        func didDisappear() {}
        func didTapRefresh() {}
        func didToggleResource(_: String) {}
        func didToggleBlockers(_: String) {}
        func didOpenOwner(_ id: String) {
            readingState.focusedRowID = id
        }

        private static func owner(
            _ id: String,
            title: String,
            status: String,
            detail: String? = nil,
            position: String? = nil,
            action: ResourceSlotsOwner.Action? = nil
        ) -> ResourceSlotsOwner {
            ResourceSlotsOwner(id: id, title: title, ownerID: "task-1", status: status, since: nil,
                               detail: detail, position: position, action: action, blockers: nil)
        }
    }
}
