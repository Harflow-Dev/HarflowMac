import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - StatusGlyphCaptureHostedTests

/// Review evidence for the task status glyphs on every surface that draws one: the real sidebar shell, shared task and
/// group rows in both appearances, every `StatusBadge`, the top bar badge, the Statistics ranking row and the workflow
/// canvas nodes. With `HARFLOW_STATUS_GLYPH_CAPTURE_DIR` set each state is written as a host bitmap, an exact owned
/// window capture and a JSON naming the HarflowDesign route, file and commit; without it the tests only assert that
/// each surface mounted.
@MainActor @Suite(.serialized) struct StatusGlyphCaptureHostedTests {
    static let captureKey = "HARFLOW_STATUS_GLYPH_CAPTURE_DIR"
    private static let design = HostedCaptureEvidence.Design(
        route: "#new-task/centered-ready", file: "v2/scripts/screens-new-task.js",
        commit: "fe6428c35d11c9b4e685c4b15527291c21c846ce"
    )

    // MARK: Fixtures

    private static func info(_ id: String, _ status: String, backend: String = "claude", group: String? = nil) -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string(backend), "status": .string(status), "repo_path": .string("/tmp/repo")
        ]
        if let group { object["group"] = .string(group) }
        return TaskInfo(.object(object))!
    }

    private static func group(_ name: String, _ members: [(String, String)]) -> ParallelGroup {
        let tasks = members.enumerated().map { index, member in
            info("\(name)-\(index)", member.1, backend: member.0, group: name)
        }
        return Lineage.sections(tasks).parallel.first!
    }

    private static func row(_ id: String, _ title: String, _ status: TaskStatus, backend: String = "claude",
                            kind: StatusIcon.Kind = .task) -> TaskRowModel {
        TaskRowModel(id: id, backend: backend, title: title, status: status, repoName: "repo", ageText: "2m",
                     durationSeconds: status.isRunning ? 90 : nil, kind: kind)
    }

    private static let multiRunning = group("Release notes", [("claude", "running"), ("codex", "completed")])
    private static let singleRunning = group("Solo run", [("claude", "running")])
    private static let finishedGroup = group("Finished run", [("claude", "completed"), ("codex", "failed")])

    /// The first sidebar page: running, grouped and waiting states.
    private static var sidebarPageA: [SidebarSection] {
        [
            SidebarSection(bucket: .running, items: [
                .task(row("g-running", "Running task", .running)),
                .group(multiRunning),
                .group(singleRunning)
            ]),
            SidebarSection(bucket: .today, items: [
                .task(row("g-pending", "Pending task", .other("pending"))),
                .task(row("g-needs-input", "Needs input task", .other("Needs Input"))),
                .task(row("g-needs-attention", "Needs attention task", .other("needs_attention"))),
                .group(finishedGroup)
            ])
        ]
    }

    /// The second sidebar page: terminal states, a workflow run and one selected row.
    private static var sidebarPageB: [SidebarSection] {
        [
            SidebarSection(bucket: .today, items: [
                .task(row("g-done", "Done task", .completed)),
                .task(row("g-failed", "Failed task", .failed)),
                .task(row("g-timed-out", "Timed out task", .timedOut)),
                .task(row("g-cancelled", "Cancelled task", .cancelled)),
                .workflow(row("g-workflow", "Completed workflow run", .completed, backend: "workflow", kind: .workflowRun)),
                .task(row("g-selected", "Selected done task", .completed))
            ])
        ]
    }

    private static func ids(_ sections: [SidebarSection]) -> Set<String> {
        Set(sections.flatMap(\.items).map(\.id))
    }

    // MARK: Plumbing

    private func record(_ host: RedesignHost, state: String, dark: Bool, size: CGSize) async throws {
        await HostedCaptureEvidence.prepare(host.window, dark: dark)
        guard let directory = HostedCaptureEvidence.directory(Self.captureKey) else { return }
        let subject = HostedCaptureEvidence.Subject(suite: "status-glyphs", state: state, dark: dark,
                                                    size: NSSize(width: size.width, height: size.height), design: Self.design)
        try await HostedCaptureEvidence.record(directory: directory, subject: subject, window: host.window, host: host.host)
    }

    private func gallery(_ view: some View, size: CGSize, dark: Bool) async -> RedesignHost {
        let host = RedesignHost(view.environment(\.hfReduceMotionOverride, true), size: size, appearance: dark ? .dark : .light)
        await host.settle { true }
        return host
    }

    // MARK: Sidebar (real shell)

    @Test(arguments: [false, true])
    func givenSidebarStates_whenRealSidebarRenders_thenEveryStateIsCaptured(dark: Bool) async throws {
        _ = NSApplication.shared
        for (page, sections) in [("a", Self.sidebarPageA), ("b", Self.sidebarPageB)] {
            // given
            let vm = SidebarViewModelMock()
            vm.sections = sections
            if page == "b" { vm.selection = .task("g-selected") }
            let size = CGSize(width: 1000, height: 1000)
            let host = NSHostingView(rootView: NavigationSplitView {
                SidebarView(vm).navigationSplitViewColumnWidth(min: 240, ideal: 340, max: 340)
            } detail: { Text("Detail") }
                .frame(minWidth: size.width, minHeight: size.height)
                .toolbar(removing: .title)
                .withPresentationContext())
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.toolbar = NSToolbar(identifier: "status-glyph-sidebar")
            window.toolbarStyle = .unified
            window.contentView = host
            window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)

            // when
            let wanted = Self.ids(sections)
            var outline: NSOutlineView?
            await waitUntil(timeout: 10) {
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                host.layoutSubtreeIfNeeded()
                guard let found = Self.outline(in: host) else { return false }
                outline = found
                let present = Set((0 ..< found.numberOfRows).compactMap { (found.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id })
                return wanted.isSubset(of: present)
            }
            let list = try #require(outline)
            let present = Set((0 ..< list.numberOfRows).compactMap { (list.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id })
            #expect(wanted.isSubset(of: present), "Missing sidebar rows: \(wanted.subtracting(present).sorted())")
            if page == "b" {
                try await select("task:g-selected", in: list, window: window)
            }
            await waitUntil(timeout: 5) {
                window.layoutIfNeeded()
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
                return list.numberOfRows > 0 && list.rect(ofRow: list.numberOfRows - 1).height > 0
            }
            await HostedCaptureEvidence.prepare(window, dark: dark)

            // then
            if let directory = HostedCaptureEvidence.directory(Self.captureKey) {
                let subject = HostedCaptureEvidence.Subject(suite: "status-glyphs", state: "sidebar-\(page)", dark: dark,
                                                            size: NSSize(width: size.width, height: size.height), design: Self.design)
                try await HostedCaptureEvidence.record(directory: directory, subject: subject, window: window, host: host)
            }
        }
    }

    /// Selects the row with `id` through the native outline and waits until it is the only selected row.
    private func select(_ id: String, in list: NSOutlineView, window: NSWindow) async throws {
        let row = try #require((0 ..< list.numberOfRows).first { (list.item(atRow: $0) as? SidebarNativeItemBox)?.entry.id == id })
        list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        await waitUntil(timeout: 5) {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
            return list.selectedRowIndexes == IndexSet(integer: row) && (list.rowView(atRow: row, makeIfNecessary: false)?.isSelected ?? false)
        }
        #expect(list.selectedRowIndexes == IndexSet(integer: row), "The selected row must be selected before recording")
    }

    private static func outline(in view: NSView) -> NSOutlineView? {
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        return all(view).compactMap { $0 as? NSOutlineView }.first
    }

    // MARK: Shared rows (sidebar and menu-bar appearance)

    private struct RowsGallery: View {
        let sidebar: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { model in
                    TaskRow(model: model, sidebarAppearance: sidebar ? SidebarRowAppearance() : nil,
                            metadataForeground: sidebar ? nil : .primaryText)
                }
                ForEach(groups, id: \.id) { group in
                    GroupRow(group: group, sidebarAppearance: sidebar ? SidebarRowAppearance() : nil,
                             metadataForeground: sidebar ? nil : .primaryText)
                }
            }
            .padding(.horizontal, HfRadius.Metrics.spacing12)
            .frame(width: 340)
            .background(sidebar ? AnyShapeStyle(Color.sidebarBG) : AnyShapeStyle(.ultraThinMaterial))
        }

        private var rows: [TaskRowModel] {
            [
                StatusGlyphCaptureHostedTests.row("r-done", "Done", .completed),
                StatusGlyphCaptureHostedTests.row("r-failed", "Failed", .failed),
                StatusGlyphCaptureHostedTests.row("r-timed-out", "Timed out", .timedOut),
                StatusGlyphCaptureHostedTests.row("r-cancelled", "Cancelled", .cancelled),
                StatusGlyphCaptureHostedTests.row("r-needs-input", "Needs input", .other("Needs Input")),
                StatusGlyphCaptureHostedTests.row("r-needs-attention", "Needs attention", .other("needs_attention")),
                StatusGlyphCaptureHostedTests.row("r-running", "Running", .running),
                StatusGlyphCaptureHostedTests.row("r-pending", "Pending", .other("pending")),
                StatusGlyphCaptureHostedTests.row("r-workflow", "Workflow run done", .completed, backend: "workflow", kind: .workflowRun)
            ]
        }

        private var groups: [ParallelGroup] {
            [StatusGlyphCaptureHostedTests.multiRunning, StatusGlyphCaptureHostedTests.singleRunning,
             StatusGlyphCaptureHostedTests.finishedGroup]
        }
    }

    @Test(arguments: [false, true], [false, true])
    func givenRows_whenSharedRowsRender_thenSidebarAndMenuBarAppearancesAreCaptured(dark: Bool, sidebar: Bool) async throws {
        // given
        #expect(Self.sidebarPageB.flatMap(\.items).contains { if case let .workflow(row) = $0 { row.kind == .workflowRun } else { false } })
        let size = CGSize(width: 340, height: 700)
        let host = await gallery(RowsGallery(sidebar: sidebar), size: size, dark: dark)
        defer { host.close() }

        // when / then
        try await record(host, state: sidebar ? "rows-sidebar" : "rows-menu-bar", dark: dark, size: size)
        #expect(host.host.fittingSize.height > 0)
    }

    // MARK: Badges

    private struct BadgesGallery: View {
        private static let statuses: [TaskStatus] = [
            .running, .completed, .failed, .timedOut, .cancelled, .other("pending"), .other("needs_input"),
            .other("needs_attention"), .other("settling"), .other("mystery-state")
        ]

        var body: some View {
            VStack(alignment: .leading, spacing: HfRadius.Metrics.spacing12) {
                Text("StatusBadge").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                ForEach(Array(Self.statuses.enumerated()), id: \.offset) { _, status in
                    StatusBadge(status: status, elapsedText: status == .running ? "1:30" : nil)
                }
                Text("Top bar badge").font(.hf(.caption)).foregroundStyle(Color.secondaryText)
                ForEach(Array([TaskStatus.other("needs_input"), .timedOut, .failed, .other("needs_attention")].enumerated()), id: \.offset) { _, status in
                    TaskStatusBadge(model: .make(
                        evidence: TaskSnapshotEvidence(status: status, takenOver: false, snapshotStatus: nil, exitCode: nil,
                                                       logState: nil, ownerState: nil, settledDuration: nil),
                        startedAt: nil
                    ))
                }
            }
            .padding(HfRadius.Metrics.spacing16)
            .frame(width: 280, alignment: .leading)
            .background(Color.windowBG)
        }
    }

    @Test(arguments: [false, true])
    func givenBadges_whenRendered_thenStatusBadgesAndTopBarBadgesAreCaptured(dark: Bool) async throws {
        // given
        let size = CGSize(width: 280, height: 640)
        let host = await gallery(BadgesGallery(), size: size, dark: dark)
        defer { host.close() }

        // when / then
        try await record(host, state: "badges", dark: dark, size: size)
        #expect(host.host.fittingSize.height > 0)
    }

    // MARK: Statistics

    @Observable @MainActor final class StatisticsModel: StatisticsViewModel {
        var presentation: StatisticsPresentation = {
            var value = StatisticsPresentation()
            value.state = .ready
            let icons: [(String, String, TaskStatus, StatusIcon.Kind)] = [
                ("done", "Done", .completed, .task), ("workflow", "Workflow done", .completed, .workflowRun),
                ("failed", "Failed", .failed, .task), ("timed", "Timed out", .timedOut, .task), ("cancelled", "Cancelled", .cancelled, .task)
            ]
            let children = icons.map { id, title, status, kind in
                StatisticsChildRow(id: id, title: title, subtitle: "Oct 25, 10:00", value: "42 min", secondaryValue: "20 k tokens",
                                   fraction: 0.6, statusIcon: StatisticsStatusIcon(status: status, kind: kind), statusLabel: title)
            }
            value.rows = [StatisticsRow(
                id: "workflow", title: "Implement and review", subtitle: "96 runs", value: "38 h 12 min", secondaryValue: "2.6 M tokens",
                fraction: 1, isExpanded: true, children: children, childrenTitle: "Workflow runs, longest first",
                childrenFooter: "Showing 5 of 96 runs", canShowNodes: true, rank: 1,
                glyph: "point.3.connected.trianglepath.dotted", share: "100%", kindLabel: "Workflow"
            )]
            return value
        }()

        func didAppear() {}
        func didDisappear() {}
        func selectRange(_: StatisticsRange) {}
        func selectMeasure(_: StatisticsMeasure) {}
        func selectList(_: StatisticsList) {}
        func selectRepository(_: String?) {}
        func selectHarness(_: String?) {}
        func selectRequestedModel(_: String?) {}
        func toggleRow(_: String) {}
        func showNodes(for _: String) {}
        func showOverview() {}
        func retry() {}
    }

    @Test(arguments: [false, true])
    func givenExpandedRanking_whenStatisticsRenders_thenRowStatusGlyphsAreCaptured(dark: Bool) async throws {
        // given
        let size = CGSize(width: 1000, height: 820)
        let host = await gallery(StatisticsView(StatisticsModel()).frame(width: size.width, height: size.height), size: size, dark: dark)
        defer { host.close() }

        // when / then
        try await record(host, state: "statistics-ranking", dark: dark, size: size)
        #expect(host.host.fittingSize.height > 0)
    }

    // MARK: Workflow canvas nodes

    @Test(arguments: [false, true])
    func givenAttentionNodes_whenCanvasRenders_thenCompactAndRegularNodesAreCaptured(dark: Bool) async throws {
        // given
        func node(_ id: String, _ type: String, x: Double, y: Double) -> WorkflowNodeModel {
            WorkflowNodeModel(raw: ["id": .string(id), "title": .string(id), "type": .string(type), "role": .string("task"),
                                    "position": .object(["x": .number(x), "y": .number(y)]),
                                    "agent": .object(["backend": .string("codex"), "model": .string("gpt")])])
        }
        let statuses = ["start": "needs_attention", "end": "needs_input", "agent-a": "needs_attention", "agent-b": "needs_input",
                        "agent-c": "completed", "agent-d": "failed"]
        let nodes = [node("start", "start", x: 40, y: 40), node("end", "end", x: 160, y: 40),
                     node("agent-a", "agent", x: 40, y: 150), node("agent-b", "agent", x: 270, y: 150),
                     node("agent-c", "agent", x: 40, y: 270), node("agent-d", "agent", x: 270, y: 270)]
        let size = CGSize(width: 520, height: 400)
        let canvas = WorkflowCanvas(nodes: nodes, edges: [], selectedNodeID: nil, selectedEdgeID: nil, isEditable: false,
                                    status: { statuses[$0] ?? "pending" }, attempt: { _ in 0 }, onSelectNode: { _ in },
                                    onSelectEdge: { _ in }, onMove: { _, _ in }, onConnect: { _ in }, onDrop: { _, _ in },
                                    showsExecutionStates: true)
            .frame(width: size.width, height: size.height)
        let host = await gallery(canvas, size: size, dark: dark)
        defer { host.close() }
        await host.settle { host.element("agent-a") != nil }

        // when / then
        try await record(host, state: "canvas-nodes", dark: dark, size: size)
        #expect(host.host.fittingSize.height > 0)
    }
}
