import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - M05ActionsTopBarStateMatrixHostedTests

/// Native evidence for the nine Actions and Top bar states of HarflowDesign `v2/scripts/screens-m05-proposal.js` (pin
/// 4ff7d83): the overflow menu, the Stop and takeover confirmations, and the top bar's chips, resource card and minimum
/// width. Each is the production shell with a real standalone `TaskDetailVM`. The assertions state what native renders.
@MainActor
@Suite(.serialized)
struct M05ActionsTopBarStateMatrixHostedTests {
    nonisolated static let states = M05StateTable.ids(.actionsTopBar)

    @Test(arguments: states, [false, true])
    func givenApprovedActionState_whenHostedInBothSizes_thenNativeStateRenders(state: String, dark: Bool) async throws {
        // given / when / then
        try await M05MatrixRunner.run(Self.spec(state), dark: dark)
    }

    // MARK: Recipes

    static func spec(_ state: String) -> M05MatrixRunner.Spec {
        switch state {
        case "overflow-running", "overflow-settled", "overflow-subtask": overflow(state)
        case "stop-dialog", "stop-dialog-earlier-turns": stopDialog(state)
        case "takeover-dialog": takeoverDialog()
        case "topbar-facts": topBarFacts()
        case "topbar-resource": topBarResource()
        case "topbar-minimum": topBarMinimum()
        default: preconditionFailure("No recipe for action state \(state)")
        }
    }

    private static func config(_ configure: @escaping @Sendable (inout TopBarIntegratedFixture.Config) -> Void = { _ in })
        -> @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config {
        { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = "Fix the flaky retry path in the slot release"
            config.notices = 0
            config.continuity = false
            config.closePane = true
            configure(&config)
            return config
        }
    }

    // MARK: Overflow

    private static func overflow(_ state: String) -> M05MatrixRunner.Spec {
        let parent = M05Fixtures.task(status: "completed", fields: ["task_id": .string("parent01")])
        let task: TaskInfo = switch state {
        case "overflow-settled": M05Fixtures.settled()
        case "overflow-subtask": M05Fixtures.task(status: "running", fields: ["spawned_by": .string("parent01"), "resume_command": .string("fixture resume")])
        default: M05Fixtures.task(status: "running", fields: ["resume_command": .string("fixture resume")])
        }
        let expected: [String] = switch state {
        case "overflow-settled": ["Open in terminal", "Copy resume command", "Copy task ID", "Open in Finder", "Copy path"]
        case "overflow-subtask": ["Stop task…", "Take over in terminal", "Open parent task", "Copy resume command", "Copy task ID",
                                  "Open in Finder", "Copy path"]
        default: ["Stop task…", "Take over in terminal", "Copy resume command", "Copy task ID", "Open in Finder", "Copy path"]
        }
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: state, config: config { configuration in
            if state == "overflow-settled" { configuration.closePane = false; configuration.openPane = true; configuration.paneTab = .changes }
        }, build: {
            let fixtures = TaskDetailVMTests.Fixtures()
            fixtures.taskProvider.value = { id in id == "parent01" ? parent : id == M05Fixtures.taskID ? task : nil }
            return .init(harness: M05Fixtures.harness(task, fixtures: fixtures))
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in
            ctx.fixture.item(TopBarIntegratedFixture.more).flatMap(\.view) != nil && ctx.vm.task != nil && ctx.vm.canTakeover
        }, verify: { ctx in
            let titles = try menuTitles(ctx)
            #expect(titles == expected, "overflow items \(ctx.name): \(titles)")
            if state == "overflow-settled" {
                #expect(!titles.contains("Stop task…"), "no Stop item once settled \(ctx.name)")
                #expect(ctx.fixture.hasPane, "pane open on Changes \(ctx.name)")
            } else {
                #expect(titles.first == "Stop task…", "Stop is the first item \(ctx.name)")
            }
        })
    }

    /// Opens the More menu through the toolbar item's native popup and returns its command titles in order, without the
    /// repository heading.
    static func menuTitles(_ ctx: M05MatrixRunner.Context) throws -> [String] {
        let view = try #require(ctx.fixture.item(TopBarIntegratedFixture.more)?.view, "no More item \(ctx.name)")
        func popUps(_ view: NSView) -> [NSPopUpButton] { (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap(popUps) }
        let button = try #require(popUps(view).first, "no popup button \(ctx.name)")
        let capture = OverflowTrackingCapture(button: button)
        NotificationCenter.default.addObserver(capture, selector: #selector(OverflowTrackingCapture.didBegin(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        let deadline = Timer(timeInterval: 5, target: capture, selector: #selector(OverflowTrackingCapture.expire(_:)), userInfo: nil, repeats: false)
        RunLoop.main.add(deadline, forMode: .common)
        RunLoop.main.add(deadline, forMode: .eventTracking)
        defer { deadline.invalidate(); NotificationCenter.default.removeObserver(capture); capture.menu?.cancelTracking() }
        button.performClick(nil)
        let menu = try #require(capture.menu, "menu did not open \(ctx.name)")
        #expect(!capture.timedOut, "menu tracking timed out \(ctx.name)")
        let heading = Format.repoName("/repo")
        return menu.items.filter { !$0.isSeparatorItem && $0.title != heading }.map(\.title)
    }

    // MARK: Stop and takeover confirmations

    private final class StopHolder { var request: TaskStopConfirmation? }

    private static func stopDialog(_ state: String) -> M05MatrixRunner.Spec {
        let earlier = state == "stop-dialog-earlier-turns"
        let holder = StopHolder()
        let current = M05Fixtures.task(status: "running")
        let previous = M05Fixtures.task(status: "running", fields: ["task_id": .string("earlier01")])
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: state, config: config(), build: {
            let fixtures = TaskDetailVMTests.Fixtures()
            if earlier {
                fixtures.conversationMembersProvider.value = { _ in [previous, current] }
                fixtures.taskProvider.value = { id in id == "earlier01" ? previous : id == M05Fixtures.taskID ? current : nil }
            }
            let harness = M05Fixtures.harness(current, fixtures: fixtures)
            if earlier { M05Fixtures.installMember(previous, conversation: [previous, current], on: harness) }
            given(harness.routing).presentStopConfirmation(.any).willProduce { holder.request = $0 }
            return .init(harness: harness, retained: [holder])
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([current])
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.has("Stop") }
            if let stop = ctx.element("Stop") { _ = ShellMatrix.press(stop) }
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return holder.request != nil }
            guard let request = holder.request else { return }
            ctx.coordinator.stopConfirmationBuilder = {
                TaskStopConfirmationView(confirmation: request) {
                    ctx.coordinator.isStopConfirmationPresented = false
                    request.confirm()
                }.eraseToAnyView()
            }
            ctx.coordinator.isStopConfirmationPresented = true
        }, ready: { ctx in ctx.window.attachedSheet.map { ShellMatrix.contains("Stop this task?", in: $0) } ?? false },
        verify: { ctx in
            let sheet = try #require(ctx.window.attachedSheet, "stop sheet \(ctx.name)")
            for text in ["Stop this task?",
                         "Harflow asks this run and the tasks it started through Harflow to stop. This is best effort.",
                         "Files already written stay in place.",
                         "Builds and other background processes the run started can keep running. Harflow can't list them.",
                         "Keep running", "Stop task"] {
                #expect(ShellMatrix.contains(text, in: sheet), "\(text) \(ctx.name)")
            }
            #expect(ShellMatrix.contains("Won't be stopped by this", in: sheet) == earlier, "lineage list presence \(ctx.name)")
            if earlier {
                #expect(ShellMatrix.contains("From the task list, not from the engine's cancel result. May be out of date.", in: sheet),
                        "client-derived label \(ctx.name)")
                #expect(holder.request?.notStoppedTitles == ["Task earlier0"], "titles \(holder.request?.notStoppedTitles ?? [])")
            } else {
                #expect(holder.request?.notStoppedTitles.isEmpty == true)
            }
        }, finish: { ctx in
            ctx.coordinator.isStopConfirmationPresented = false
            await waitUntil(timeout: 5) { ctx.fixture.pump(); return ctx.window.attachedSheet == nil }
        })
    }

    private static func takeoverDialog() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.task(status: "running")
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: "takeover-dialog", config: config(), build: {
            .init(harness: M05Fixtures.harness(task))
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([task])
            await waitUntil(timeout: 10) { ctx.fixture.pump(); return ctx.vm.canTakeover }
            ctx.vm.didTapTakeover()
        }, ready: { ctx in ctx.window.attachedSheet.map { ShellMatrix.contains("Take over this task?", in: $0) } ?? false },
        verify: { ctx in
            let sheet = try #require(ctx.window.attachedSheet, "takeover dialog \(ctx.name)")
            #expect(ShellMatrix.contains("Take over this task?", in: sheet))
            #expect(ShellMatrix.contains("Take over in terminal", in: sheet))
            #expect(ShellMatrix.contains("Cancel", in: sheet))
            let opening = "The headless run is stopped first (with any sub-tasks), then the same conversation opens in Terminal.app."
            #expect(ShellMatrix.hasPrefix(opening, in: sheet), "body \(ctx.name)")
        }, finish: { ctx in
            if let sheet = ctx.window.attachedSheet, let cancel = ShellMatrix.element("Cancel", in: sheet) { _ = ShellMatrix.press(cancel) }
            await waitUntil(timeout: 5) { ctx.fixture.pump(); return ctx.window.attachedSheet == nil }
        })
    }

    // MARK: Top bar

    private static func topBarFacts() -> M05MatrixRunner.Spec {
        let setup: @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config = { _ in
            var configuration = TopBarIntegratedFixture.Config()
            configuration.title = "Fix the flaky retry path in the slot release"
            configuration.openPane = true
            configuration.expandedGroups = [.notices]
            return configuration
        }
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: "topbar-facts", config: setup, build: {
            let configuration = setup(NSSize(width: 1280, height: 800))
            let task = TopBarIntegratedFixture.task(configuration, notices: configuration.notices)
            let harness = M05Fixtures.harness(task)
            harness.snapshotBox.value = TopBarIntegratedFixture.enforcementSnapshot(of: task)
            return .init(harness: harness)
        }, ready: { ctx in ctx.fixture.hasPane && ctx.fixture.groupValue("Notices") == "Expanded" }, verify: { ctx in
            let content = try #require(ctx.fixture.content, "published content \(ctx.name)")
            let expected = ctx.fixture.expectedItems(chips: TopBarChip.allCases, content: content)
            for item in expected {
                let rendered = ctx.fixture.renderedItem(item)
                #expect(rendered != nil, "chip \(item.name) rendered \(ctx.name); items \(ctx.fixture.itemIdentifiers)")
                #expect(ctx.fixture.isOnScreen(rendered), "chip \(item.name) on screen \(ctx.name)")
            }
            #expect(ctx.fixture.store.selectedTab(for: TopBarIntegratedFixture.conversation) == .events)
            #expect(ctx.fixture.groupValue("Notices") == "Expanded")
        })
    }

    private static func topBarResource() -> M05MatrixRunner.Spec {
        let setup: @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config = { _ in
            var configuration = TopBarIntegratedFixture.Config()
            configuration.title = "Run the heavy build and the full test suite"
            configuration.notices = 0
            configuration.continuity = false
            configuration.resourceHeld = true
            configuration.closePane = true
            return configuration
        }
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: "topbar-resource", config: setup, build: {
            let configuration = setup(NSSize(width: 1280, height: 800))
            return .init(harness: M05Fixtures.harness(TopBarIntegratedFixture.task(configuration, notices: 0)))
        }, ready: { ctx in ctx.fixture.resourceCardTitle("Holding heavy-build") != nil }, verify: { ctx in
            #expect(ctx.fixture.resourceCardTitle("Holding heavy-build") != nil)
            #expect(ctx.fixture.itemRendering("Back to resource slots") == nil, "no resource return button \(ctx.name)")
        })
    }

    private static func topBarMinimum() -> M05MatrixRunner.Spec {
        let setup: @MainActor @Sendable (NSSize) -> TopBarIntegratedFixture.Config = { _ in
            var configuration = TopBarIntegratedFixture.Config()
            configuration.title = TopBarIntegratedFixture.TitleKind.long.text
            configuration.badge = TopBarIdealWidths.widestBadge()
            configuration.resourceReturn = true
            configuration.closePane = true
            return configuration
        }
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.actionsTopBar.rawValue, state: "topbar-minimum", config: setup, build: {
            let configuration = setup(NSSize(width: 1000, height: 620))
            return .init(harness: M05Fixtures.harness(TopBarIntegratedFixture.task(configuration, notices: configuration.notices)))
        }, ready: { ctx in ctx.fixture.principalItem != nil && ctx.fixture.itemRendering("Back to resource slots") != nil },
        verify: { ctx in
            let expectedBand: TopBarWidthBand = ctx.size.width < 1100 ? .narrow : .regular
            #expect(ctx.fixture.band == expectedBand, "width band \(ctx.name): \(ctx.fixture.band)")
            let content = try #require(ctx.fixture.content, "published content \(ctx.name)")
            let principal = try #require(ctx.fixture.principalItem)
            #expect(ctx.fixture.isOnScreen(principal), "principal on screen \(ctx.name)")
            #expect(ctx.fixture.isOnScreen(ctx.fixture.item(TopBarIntegratedFixture.more)))
            #expect(ctx.fixture.isOnScreen(ctx.fixture.item(TopBarIntegratedFixture.inspector)))
            #expect(ctx.fixture.itemRendering("Back to resource slots") != nil, "resource return drawn \(ctx.name)")
            let chips = content.chips(isNarrow: ctx.fixture.band.isNarrow)
            if ctx.fixture.band.isNarrow {
                // Meta is dropped first at the minimum width; the chips stay with their counts.
                let meta = content.metaParts.joined(separator: " ")
                if !meta.isEmpty { #expect(!ctx.principalStrings.contains { $0.contains(meta) }, "meta dropped \(ctx.name) \(ctx.principalStrings)") }
                #expect(ctx.fixture.itemRendering(chips.accessLabel) != nil, "access chip \(chips.accessLabel) \(ctx.name)")
            }
            #expect(ctx.fixture.itemRendering(chips.noticesLabel) != nil, "notices chip \(chips.noticesLabel) \(ctx.name)")
        })
    }
}
