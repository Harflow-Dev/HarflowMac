import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - M05PaneStateMatrixHostedTests

/// Native evidence for the five Layout and six Events states of HarflowDesign `v2/scripts/screens-m05-proposal.js` (pin
/// 4ff7d83), each in the production shell with a real standalone `TaskDetailVM`. `pane-overlay` mounts only at 1000x620 and
/// `pane-split` only at 1280x800. Two Events states have no native copy for the design's wording (`events-page-error`,
/// `events-empty`); the matrix asserts what native renders and the receipt records the difference.
@MainActor
@Suite(.serialized)
struct M05PaneStateMatrixHostedTests {
    nonisolated static let states = M05StateTable.ids(.pane)

    @Test(arguments: states, [false, true])
    func givenApprovedPaneState_whenHosted_thenNativeStateRenders(state: String, dark: Bool) async throws {
        // given / when / then
        try await M05MatrixRunner.run(Self.spec(state), dark: dark)
    }

    // MARK: Recipes

    static func spec(_ state: String) -> M05MatrixRunner.Spec {
        switch state {
        case "pane-overlay", "pane-split": layout(state)
        case "pane-running-closed", "pane-running-open": running(state)
        case "pane-failed-closed": failedClosed()
        default: events(state)
        }
    }

    private static func config(_ configure: @escaping @Sendable (inout TopBarIntegratedFixture.Config) -> Void = { _ in })
        -> @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config {
        { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = "Fix the flaky retry path in the slot release"
            config.notices = 0
            config.continuity = false
            configure(&config)
            return config
        }
    }

    private static let sunkenPane = "Task details"

    /// Common to every state with the pane open: its width, the three tabs and the close button.
    private static func assertPaneChrome(_ ctx: M05MatrixRunner.Context) throws {
        let pane = try #require(ctx.fixture.contentElement(labelled: sunkenPane), "pane \(ctx.name)")
        let frame = try #require(ctx.fixture.screenFrame(ofElement: pane))
        #expect(abs(frame.width - 420) <= 3, "pane width \(frame.width) \(ctx.name)")
        let content = ctx.window.convertToScreen(ctx.host.bounds)
        #expect(abs(frame.maxX - content.maxX) <= 3, "pane trailing edge \(ctx.name)")
        for tab in ["Changes", "Artifacts", "Events"] { #expect(ShellMatrix.contains(tab, in: pane), "tab \(tab) in the pane \(ctx.name)") }
        #expect(ShellMatrix.contains("Close right pane", in: pane), "close button in the pane \(ctx.name)")
    }

    // MARK: Layout

    private static func layout(_ state: String) -> M05MatrixRunner.Spec {
        let overlay = state == "pane-overlay"
        let task = M05Fixtures.settled()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.pane.rawValue, state: state, sizes: [overlay ? ShellMatrix.sizes[1] : ShellMatrix.sizes[0]],
                                    config: config { $0.openPane = true; $0.paneTab = .changes }, build: {
            .init(harness: M05Fixtures.harness(task))
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in ctx.fixture.hasPane && ctx.fixture.transcriptFrame != nil },
        verify: { ctx in
            try assertPaneChrome(ctx)
            let pane = try #require(ctx.fixture.contentElement(labelled: sunkenPane))
            let paneFrame = try #require(ctx.fixture.screenFrame(ofElement: pane))
            let transcript = try #require(ctx.fixture.transcriptFrame, "transcript \(ctx.name)")
            #expect(ctx.fixture.store.selectedTab(for: TopBarIntegratedFixture.conversation) == .changes)
            if overlay {
                #expect(ctx.size.width == 1000)
                // Modality of the overlay is asserted by `TaskPaneHostedTests` on the standalone mount; the shell keeps its sidebar reachable.
                #expect(transcript.intersects(paneFrame), "overlay covers the transcript \(ctx.name)")
            } else {
                #expect(ctx.size.width == 1280)
                #expect(ctx.has("Queue a message…"), "split pane leaves the composer reachable \(ctx.name)")
                #expect(transcript.maxX <= paneFrame.minX + 2, "split pane sits beside the transcript \(ctx.name)")
            }
        })
    }

    private static func running(_ state: String) -> M05MatrixRunner.Spec {
        let open = state == "pane-running-open"
        let task = M05Fixtures.task(status: "running")
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.pane.rawValue, state: state, config: config { $0.openPane = open }, build: {
            .init(harness: M05Fixtures.harness(task))
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in
            ctx.vm.task != nil && (open ? ctx.fixture.hasPane : ctx.has("Stop"))
        }, verify: { ctx in
            if open {
                try assertPaneChrome(ctx)
                #expect(ctx.fixture.store.selectedTab(for: TopBarIntegratedFixture.conversation) == .events)
            } else {
                #expect(!ctx.fixture.hasPane, "pane stays closed while running \(ctx.name)")
                #expect(ctx.fixture.store.openChoice(for: TopBarIntegratedFixture.conversation) == .noChoice, "no stored choice \(ctx.name)")
            }
        })
    }

    private static func failedClosed() -> M05MatrixRunner.Spec {
        M05MatrixRunner.Spec(suite: M05StateTable.Suite.pane.rawValue, state: "pane-failed-closed", config: config(), build: {
            let fixture = HostedContinuationFixture()
            fixture.publish([HostedContinuationFixture.task(status: "failed")])
            return .init(harness: fixture.vm, retained: [fixture])
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([HostedContinuationFixture.task(status: "failed")])
        }, ready: { ctx in ctx.has("Task failed: the harness exited with code 1") }, verify: { ctx in
            #expect(!ctx.fixture.hasPane, "pane stays closed for a failed task \(ctx.name)")
            #expect(ctx.has("Task failed: the harness exited with code 1"))
            #expect(ctx.fixture.store.openChoice(for: TopBarIntegratedFixture.conversation) == .noChoice)
        })
    }

    // MARK: Events

    private static var twoToolCalls: ActivityCounts {
        var counts = ActivityCounts()
        counts.toolCalls = 2
        return counts
    }

    private static func eventsFrame(_ state: String, rows: [TimelineItem]) -> EventObservationFrame? {
        switch state {
        case "events-page":
            M05Fixtures.frame(items: rows, records: M05Fixtures.records(["notice"]),
                              history: .init(hasOlder: true, caughtUp: false, forwardDrained: true, availableActions: [.loadEarlier]),
                              summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        case "events-page-error":
            M05Fixtures.frame(items: rows, records: M05Fixtures.records(["notice"]),
                              history: .init(hasOlder: true, caughtUp: false, forwardDrained: true, availableActions: [.retryRead]),
                              summary: .init(state: .observed, counts: ActivityCounts(), totalFiles: 0))
        case "events-loading":
            EventObservationFrame(taskID: M05Fixtures.taskID, scope: FeatureObservationFixture.scope, history: .init(isLoading: true))
        case "events-empty":
            M05Fixtures.frame(items: [], summary: .init(state: .observed, counts: ActivityCounts(), files: [], totalFiles: 0))
        case "events-error":
            M05Fixtures.frame(items: [], history: .init(reasons: [.unavailable], availableActions: [.retryRead]), logState: .unavailable,
                              summary: .init(state: .unavailable, reasons: [.unavailable]))
        default:
            M05Fixtures.frame(items: rows, records: M05Fixtures.records(["notice", "tool_result"]),
                              summary: .init(state: .observed, counts: twoToolCalls, totalFiles: 0))
        }
    }

    /// The Events pane's own summary line for each state, asserted inside the pane at both sizes.
    private static func paneSummary(_ state: String) -> String {
        switch state {
        case "events-populated": "2 tool calls observed"
        case "events-loading": "Loading tool activity"
        case "events-error": "Tool activity unavailable"
        case "events-empty": "No rows in the available captured history"
        default: "No tool calls observed in the available captured history"
        }
    }

    /// In the 1000 x 620 overlay the pane is modal, so SwiftUI hides the transcript column's own views (the history boundary and
    /// its actions) from accessibility; those transcript landmarks are asserted at 1280 x 800 only, the pane's at both sizes.
    private static func verifyEvents(_ state: String, _ ctx: M05MatrixRunner.Context) {
        let overlay = ctx.size.width < 1100
        #expect(ctx.inPane("Captured activity"), "events section heading in the pane \(ctx.name)")
        if state != "events-empty" {
            #expect(ctx.paneContains("Public normalized events · bounded record window"), "events section in the pane \(ctx.name)")
        }
        #expect(ctx.paneContains(paneSummary(state)), "pane summary \(paneSummary(state)) \(ctx.name)")
        if state != "events-populated" { #expect(!ctx.paneContains("Task failed"), "history state is not a task failure \(ctx.name)") }
        switch state {
        case "events-populated":
            for group in ["Task", "What was enforced", "Notices"] {
                #expect(ctx.fixture.groupValue(group) == "Collapsed", "\(group) group collapsed by default \(ctx.name): \(ctx.fixture.groupHeaderLabels)")
            }
            for kind in ["notice", "tool_result"] { #expect(ctx.paneContains(kind), "record kind \(kind) listed in the pane \(ctx.name)") }
        case "events-page":
            if !overlay { #expect(ctx.outsidePaneHas("Load earlier"), "history action on the transcript boundary \(ctx.name)") }
            #expect(ctx.paneHasIdentifier("task-events.load-earlier"), "Load earlier is in the pane \(ctx.name)")
        case "events-page-error":
            if !overlay { #expect(ctx.outsidePaneHas("Retry history read"), "history action on the transcript boundary \(ctx.name)") }
            #expect(ctx.paneContains("Captured history unavailable"), "history note in the pane \(ctx.name)")
            #expect(ctx.paneContains("The read could not be completed. This does not mean the task failed."), "history note detail \(ctx.name)")
            #expect(ctx.paneHasIdentifier("task-events.retry-history-read"), "retry in the pane \(ctx.name)")
            #expect(!ctx.paneHasIdentifier("task-events.load-earlier"), "Load earlier yields to the note in the pane \(ctx.name)")
            #expect(ctx.paneContains("notice"), "retained record still listed in the pane \(ctx.name)")
            #expect(!ctx.has("Earlier records couldn't be read"), "design heading is not native copy \(ctx.name)")
            #expect(!ctx.has("Reload from newest"), "design action is not native copy \(ctx.name)")
        case "events-loading":
            if !overlay { #expect(ctx.outsidePaneHas("Loading captured history"), "transcript boundary note \(ctx.name)") }
            #expect(!ctx.paneContains("No tool calls observed in the available captured history"), "loading never reads as empty \(ctx.name)")
        case "events-empty":
            #expect(ctx.paneContains("An empty window does not qualify totals."), "empty window caption \(ctx.name)")
            #expect(!ctx.paneContains("Public normalized events · bounded record window"), "no records caption for an empty window \(ctx.name)")
        case "events-error":
            #expect(ctx.paneContains("Captured history unavailable"), "history note \(ctx.name)")
            #expect(ctx.paneContains("The read could not be completed. This does not mean the task failed."), "history note detail \(ctx.name)")
            #expect(ctx.paneHasIdentifier("task-events.retry-history-read"), "retry in the pane \(ctx.name)")
            if !overlay { #expect(ctx.outsidePaneHas("History incomplete or unavailable · see Events"), "transcript boundary note \(ctx.name)") }
        default:
            if !overlay { #expect(ctx.has("History incomplete or unavailable · see Events"), "transcript boundary note \(ctx.name)") }
            #expect(!ctx.has("Captured history unavailable"), "design heading is not native copy \(ctx.name)")
            #expect(!ctx.has("This does not mean the task failed."), "design sentence is not native copy \(ctx.name)")
        }
    }

    private static func events(_ state: String) -> M05MatrixRunner.Spec {
        let task = M05Fixtures.settled(fields: ["notices": .array([.string("Notice 1: the checkout is on the default branch.")])])
        let rows = [M05Fixtures.text(1, "Captured activity stays readable.")]
        let frame = eventsFrame(state, rows: rows)
        let landmark = switch state {
        case "events-populated": "Task details"
        case "events-page": "Load earlier"
        case "events-page-error": "Retry history read"
        case "events-loading": "Loading captured history"
        case "events-empty": "No rows in the available captured history"
        default: "History incomplete or unavailable · see Events"
        }
        // The pane repeats the history actions, so the gate waits for the transcript-side boundary where one is drawn.
        let transcriptLandmark = state != "events-empty"
        let populated = state == "events-populated"
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.pane.rawValue, state: state, config: config {
            $0.openPane = true
            $0.paneTab = .events
        }, build: {
            let harness = M05Fixtures.harness(task)
            if populated { harness.snapshotBox.value = TopBarIntegratedFixture.enforcementSnapshot(of: task) }
            harness.observationBox.value = frame
            return .init(harness: harness)
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([task])
            if let frame { M05Fixtures.publish(frame, to: ctx.harness) }
        }, ready: { ctx in
            // The history boundary sits at the top of the transcript; the shorter window realises rows from the tail.
            if let scroll = ActivityFeedTranscriptStyleHostedTests.tables(ctx.host).first?.enclosingScrollView { activityNativeTestScroll(scroll, to: 0) }
            let overlay = ctx.size.width < 1100
            let summary = ctx.paneContains(paneSummary(state))
            let landmarkShown = transcriptLandmark ? ctx.outsidePaneHas(landmark) : ctx.has(landmark)
            return ctx.fixture.hasPane && summary && (populated ? ctx.fixture.groupValue("Notices") != nil : (overlay || landmarkShown))
        }, verify: { ctx in
            try assertPaneChrome(ctx)
            #expect(ctx.fixture.store.selectedTab(for: TopBarIntegratedFixture.conversation) == .events)
            verifyEvents(state, ctx)
        })
    }
}
