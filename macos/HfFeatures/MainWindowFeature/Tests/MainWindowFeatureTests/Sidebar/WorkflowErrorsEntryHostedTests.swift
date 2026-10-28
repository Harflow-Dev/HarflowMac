import AppKit
import HfCommon
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Observation
import SwiftUI
import Testing

// MARK: - WorkflowErrorsEntryHostedTests

@MainActor @Suite(.serialized) struct WorkflowErrorsEntryHostedTests {
    @Test(arguments: [ColorScheme.light, .dark])
    func givenRetainedFailures_whenCountRetryAndRecoveryChange_thenFooterAndOpenDetailsStayCurrent(appearance: ColorScheme) async throws {
        // given
        let incidents = IncidentPresentation()
        let fixture = RedesignHost(WorkflowErrorsEntryView()
.padding()
.environment(\.incidentPresentation, incidents)
            .preferredColorScheme(appearance), size: CGSize(width: 272, height: 160))
        defer { fixture.close() }
        await fixture.settle { fixture.host.bounds.width > 0 }
        #expect(fixture.element("sidebar-workflow-errors") == nil)
        var oldRetries = 0
        var latestRetries = 0
        incidents.report(source: "read", message: "Could not read workflow.", retry: AlertAction(title: "Retry workflow") { oldRetries += 1 })
        await fixture.settle { fixture.element("Workflow errors (1)") != nil }
        incidents.dismiss()
        #expect(incidents.failures.count == 1)
        incidents.report(source: "status", message: "Could not refresh status.")
        incidents.report(source: "history", message: "Could not load history.")
        await fixture.settle { fixture.element("Workflow errors (3)") != nil }
        let entry = try #require(fixture.element("sidebar-workflow-errors"))
        #expect(fixture.press(entry))
        await fixture.settle { popoverElement("Retry workflow", fixture: fixture) != nil }
        let retainedRetry = try #require(popoverElement("Retry workflow", fixture: fixture))
        let details = try #require(popoverElement("workflow-errors-details", fixture: fixture))
        let detailsFrame = try #require(fixture.frame(details))
        #expect(abs(detailsFrame.width - HfRadius.Metrics.workflowErrorsPopoverWidth) < 2)
        #expect(detailsFrame.height > 80 && detailsFrame.height <= HfRadius.Metrics.workflowErrorsPopoverMaximumHeight + 2)

        // when: refresh the closure while preserving the failure identity and open popover.
        incidents.report(source: "read", message: "Could not read workflow.", retry: AlertAction(title: "Retry workflow") { latestRetries += 1 })
        #expect(fixture.press(retainedRetry))
        await fixture.settle { latestRetries == 1 }

        // then
        #expect(oldRetries == 0)
        #expect(latestRetries == 1)
        #expect(popoverElement("Workflow reads retry automatically.", fixture: fixture) != nil)
        incidents.resolve(source: "status")
        await fixture.settle { fixture.element("Workflow errors (2)") != nil }
        incidents.resolve(source: "read")
        incidents.resolve(source: "history")
        await fixture.settle {
            fixture.element("sidebar-workflow-errors") == nil
                && popoverElement("workflow-errors-details", fixture: fixture) == nil
        }
        #expect(incidents.failures.isEmpty)
        #expect(fixture.element("sidebar-workflow-errors") == nil)
        #expect(popoverElement("workflow-errors-details", fixture: fixture) == nil)
    }

    @Test(arguments: [true, false], [ColorScheme.light, .dark])
    func givenReadyOrSetupSidebar_whenErrorsAreRetained_thenEntryStaysAbovePreferencesWithinSidebar(ready: Bool, appearance: ColorScheme) async throws {
        // given
        let incidents = IncidentPresentation()
        incidents.report(source: "workflow", message: "Workflow unavailable.")
        let vm = SidebarViewModelMock(runtimeSetupState: ready ? .ready : .installationRequired(installedVersion: nil, requiredVersion: "0.0.2"))
        let fixture = RedesignHost(SidebarView(vm).environment(\.incidentPresentation, incidents).preferredColorScheme(appearance),
                                  size: CGSize(width: 272, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("sidebar-workflow-errors") != nil && fixture.element("Settings") != nil }
        // when / then
        let entry = try #require(fixture.element("sidebar-workflow-errors"))
        let settings = try #require(fixture.element("Settings"))
        let entryFrame = try #require(fixture.frame(entry))
        let settingsFrame = try #require(fixture.frame(settings))
        #expect(entryFrame.minX >= 0 && entryFrame.maxX <= fixture.host.bounds.width)
        #expect(entryFrame.minY >= 0 && entryFrame.maxY <= fixture.host.bounds.height)
        #expect(entryFrame.minY >= settingsFrame.maxY, "Retained errors occupy their own row above preferences")
        #expect(fixture.element("Appearance") != nil)
        if let directory = ProcessInfo.processInfo.environment["HARFLOW_WORKFLOW_ERRORS_CAPTURE_DIR"], !directory.isEmpty {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("workflow-errors-\(ready ? "ready" : "setup")-\(appearance == .dark ? "dark" : "light").png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let bitmap = try #require(fixture.host.bitmapImageRepForCachingDisplay(in: fixture.host.bounds))
            fixture.host.cacheDisplay(in: fixture.host.bounds, to: bitmap)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
        }
    }

    @Test func givenRetainedErrorsInSplitWindow_whenSummaryExpands_thenItsControlRemainsUncoveredAndActionable() async throws {
        // given
        let probe = WorkflowErrorsContextProbeState()
        let workflow = WorkflowPreview.make(run: true)
        let fixture = RedesignHost(NavigationSplitView {
            SidebarView(SidebarViewModelMock()).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: {
            WorkflowView(workflow)
        }.background(WorkflowErrorsContextProbe(state: probe)), size: CGSize(width: 1200, height: 760))
        defer { workflow.didDisappear(); fixture.close() }
        await fixture.settle { probe.binding != nil && probe.incidents != nil }
        let binding = try #require(probe.binding)
        let rootIncidents = try #require(probe.incidents)
        binding.wrappedValue = .incident(source: "workflow", message: "Workflow read failed.")
        #expect(rootIncidents.failures.count == 1)
        #expect(rootIncidents.current?.source == "workflow")
        await fixture.settle { fixture.element("sidebar-workflow-errors") != nil && fixture.element("Expand summary") != nil }
        let errorEntries = fixture.descendants
.flatMap { fixture.elements(in: $0) }
            .filter { fixture.matches($0, "Workflow errors (1)") }
        #expect(!errorEntries.isEmpty)
        #expect(errorEntries.allSatisfy { fixture.matches($0, "sidebar-workflow-errors") },
                "The root incident must expose only the sidebar entry, never a second floating retained entry")
        let entry = try #require(fixture.element("sidebar-workflow-errors"))
        let expand = try #require(fixture.element("Expand summary"))
        let entryFrame = try #require(fixture.frame(entry))
        let expandFrame = try #require(fixture.frame(expand))
        #expect(!entryFrame.intersects(expandFrame))
        // when
        #expect(fixture.press(expand))
        await fixture.settle { fixture.element("Collapse summary") != nil }
        // then
        #expect(fixture.element("Collapse summary") != nil)
        #expect(fixture.element("sidebar-workflow-errors") != nil)
    }

    private func popoverElement(_ label: String, fixture: RedesignHost) -> NSObject? {
        NSApplication.shared
.windows
.filter { $0 !== fixture.window && $0.isVisible }
.compactMap(\.contentView)
            .flatMap { fixture.elements(in: $0) }
.first { fixture.matches($0, label) }
    }
}

// MARK: - WorkflowErrorsContextProbe

@MainActor @Observable private final class WorkflowErrorsContextProbeState {
    var binding: Binding<ViewEvent>?
    var incidents: IncidentPresentation?
}

private struct WorkflowErrorsContextProbe: View {
    let state: WorkflowErrorsContextProbeState
    @Environment(\.viewEvent) private var viewEvent
    @Environment(\.incidentPresentation) private var incidents

    var body: some View {
        Color.clear.onAppear {
            state.binding = viewEvent
            state.incidents = incidents
        }
    }
}
