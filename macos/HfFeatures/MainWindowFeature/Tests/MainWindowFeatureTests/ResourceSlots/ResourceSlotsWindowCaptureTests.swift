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
        let states = ["populated", "loading", "empty", "error", "cleanup", "long-titles", "borrowed", "not-enabled", "unsupported",
                      "initial-unavailable", "service-unavailable", "retained-refresh", "cleanup-pending", "cleanup-running", "cleanup-failed", "collapsed"]
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
                await fixture.settle { resourceSlotsSidebarSearch(fixture) != nil }
                let sidebarSearch = try #require(resourceSlotsSidebarSearch(fixture),
                                                 "Production sidebar must expose its native search field and AXPlaceholderValue")
                #expect(resourceSlotsNativeValue(sidebarSearch) as? String == "retained history search")
                let searchFrame = try #require(fixture.frame(sidebarSearch))
                let fields = resourceSlotsTextFields(fixture)
                #expect(fields.count == 1, "Only the sidebar search field belongs on the Resource slots screen")
                #expect(!fields.contains { field in fixture.frame(field).map { $0.minX > searchFrame.maxX } == true },
                        "The detail pane must not add a resource search field")
                #expect(fixture.element("Search resource slots") == nil)
                if case let .ready(_, groups) = model.presentation.state {
                    for group in groups {
                        await fixture.settle { resourceSlotsCaptureHeaders(fixture, groupID: group.id).count == 1 }
                        let headers = resourceSlotsCaptureHeaders(fixture, groupID: group.id)
                        try #require(headers.count == 1, "Capture requires the actual single identified native resource header")
                        let header = try #require(headers.first)
                        let label = fixture.string(header, "accessibilityLabel") ?? fixture.string(header, "accessibilityTitle")
                        #expect(label == group.title + ", " + group.capacitySummary)
                        try resourceSlotsRequireNativeHeader(header, fixture: fixture, expanded: model.expandedResourceIDs.contains(group.id))
                    }
                }
                if state == "loading" {
                    await fixture.settle { fixture.element("Loading resource slots") != nil }
                    try #require(fixture.element("Loading resource slots") != nil)
                }
                await fixture.settle { fixture.hasStableRenderedFrame }
                try #require(fixture.hasRenderedInk, "Capture must contain actual rendered production content")
                let scheme = appearance == .light ? "light" : "dark"
                let filename = "resource-slots-\(state)-\(size.name)-\(scheme).png"
                try resourceSlotsScreenCapture(fixture.window, to: directory.appendingPathComponent(filename))
            }
        }
    }

    private func resourceSlotsCaptureHeaders(_ fixture: RedesignHost, groupID: String) -> [NSObject] {
        resourceSlotsNativeHeaders(fixture, groupID: groupID)
    }

    private func resourceSlotsTextFields(_ fixture: RedesignHost) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
            seen.insert(ObjectIdentifier($0)).inserted
                && fixture.string($0, "accessibilityRole") == NSAccessibility.Role.textField.rawValue
        }
    }

    private func resourceSlotsSidebarSearch(_ fixture: RedesignHost) -> NSObject? {
        resourceSlotsTextFields(fixture).first {
            resourceSlotsLegacyAttributeValue($0, NSAccessibility.Attribute(rawValue: "AXPlaceholderValue")) as? String == "Search loaded history"
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
            let cleanupState = state == "cleanup" || state == "service-unavailable" || state.hasPrefix("cleanup-")
            let cleanupTitle = switch state {
            case "cleanup-pending": "Cleanup pending"
            case "cleanup-running": "Cleanup running"
            case "cleanup-failed": "Cleanup failed"
            default: "Cleanup uncertain"
            }
            let group = ResourceSlotsGroup(
                id: "sim", title: groupTitle,
                capacitySummary: cleanupState ? "1 of 1 in use" : "2 of 3 in use",
                holderHeading: "Current holders",
                holders: cleanupState
                    ? [Self.owner(
                        "sim/cleanup", title: cleanupTitle, status: cleanupTitle + " · capacity retained",
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
            let qualifiers: [ResourceSlotsQualifier] = switch state {
            case "error": [.init(id: "stale", text: "Showing the last successful observations. The latest read failed.", isWarning: true)]
            case "service-unavailable": [.init(id: "service", text: "Cleanup service is not running. Cleanup capacity remains held.", isWarning: true)]
            case "retained-refresh": [.init(id: "refreshing", text: "Refreshing resource observations…", isWarning: false)]
            default: []
            }
            self.presentation = Self.preparedPresentation(state: state, group: group, qualifiers: qualifiers)
            self.expandedResourceIDs = state == "collapsed" ? [] : ["sim"]
        }

        func didAppear() {}
        func didDisappear() {}
        func didTapRefresh() {}
        func didToggleResource(_: String) {}
        func didToggleBlockers(_: String) {}
        func didOpenOwner(_ id: String) {
            readingState.focusedRowID = id
        }

        private static func preparedPresentation(state: String, group: ResourceSlotsGroup,
                                                 qualifiers: [ResourceSlotsQualifier]) -> ResourceSlotsPresentation {
            switch state {
            case "loading":
                .init(state: .loading, qualifiers: [])
            case "not-enabled":
                .init(state: .notEnabled(title: "Resource slots are not enabled",
                                         message: "The selected runtime has not enabled phase slots."), qualifiers: [])
            case "unsupported":
                .init(state: .unsupported(title: "Resource slots are unsupported",
                                          message: "The selected runtime does not support phase-slots.v1."), qualifiers: [])
            case "initial-unavailable":
                .init(state: .unavailable(title: "Resource slots are unavailable",
                                          message: "The engine did not provide qualified resource observations."), qualifiers: [])
            case "empty":
                .init(
                    state: .empty(title: "No resource slots", message: "No configured names or active reservations were reported."),
                    qualifiers: []
                )
            case "error":
                .init(
                    state: .ready(summary: "Observed holdings and queued resource entries", groups: [group]),
                    qualifiers: qualifiers
                )
            default:
                .init(state: .ready(summary: "Observed holdings and queued resource entries", groups: [group]), qualifiers: qualifiers)
            }
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
