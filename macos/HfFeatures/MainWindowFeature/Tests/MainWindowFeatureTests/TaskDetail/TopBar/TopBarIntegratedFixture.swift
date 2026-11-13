//
//  TopBarIntegratedFixture.swift
//  MainWindowFeatureTests
//

import AppKit
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - TopBarIntegratedFixture

/// The production shell (`MainWindowNavigationView`) in a real window with the real standalone `TaskDetailView` as its
/// detail, so the principal item and the task view's trailing toolbar items share one `NSToolbar`. The task view is
/// driven by a real `TaskDetailVM` (through the existing strict-mock use case), so the chips, the takeover and more items
/// and the inspector toggle are the product's own. The shell's principal content comes from the same holder the product
/// uses: the fixture publishes `TaskDetailVM.topBarContent`, with only the title and badge replaced, because the strict
/// routing mock does not forward writes. Needs the AppKit host.
@MainActor final class TopBarIntegratedFixture {

    /// How long a title is.
    enum TitleKind: CaseIterable, CustomTestStringConvertible {
        case short, medium, long

        var text: String {
            switch self {
            case .short: "Fix login bug"
            case .medium: "Investigate the flaky session refresh test"
            case .long: String(String(repeating: "Long title ", count: 11).prefix(120))
            }
        }

        var testDescription: String {
            switch self {
            case .short: "short title"
            case .medium: "medium title"
            case .long: "120 character title"
            }
        }
    }

    /// One scenario. With an injected harness the fixture builds no task, so `status`, `notices`, `continuity`, `freedom`,
    /// `enforcementSnapshot`, `resourceHeld` and `fields` are ignored (the caller's harness owns the task record); `title`,
    /// `badge`, the size, appearance, pane choices and `resourceReturn` still apply.
    struct Config {
        var width: CGFloat = 1280
        var height: CGFloat = 800
        var collapsed = false
        var title = TitleKind.medium.text
        /// Replaces the badge the VM derives; `nil` keeps the VM's own.
        var badge: TaskBadgeModel?
        var status = "running"
        var notices = 3
        var continuity = true
        /// The task's `freedom`; `nil` leaves it out, so there is no access chip.
        var freedom: String? = "write_in_repo"
        /// A matching status snapshot that carries enforcement, so the Events tab draws "What was enforced". The access chip
        /// needs only `freedom`, but its group needs `InspectorModel.showsEnforcement`, which reads the snapshot; set only by
        /// the case that reveals that group, so no other group or fixture is changed.
        var enforcementSnapshot = false
        /// The shell's "Back to resource slots" toolbar item.
        var resourceReturn = false
        /// The task holds the `heavy-build` resource, which draws the inline resource card above the transcript.
        var resourceHeld = false
        var dark = false
        var openPane = false
        /// Stores an explicit "closed" choice, so a finished task does not open the pane by its first-show default.
        var closePane = false
        /// The tab shown when `openPane` is set.
        var paneTab = TaskPaneStateStore.Tab.events
        var expandedGroups: Set<TaskPaneStateStore.FactsGroup> = []
        /// Extra task record fields merged over the generated JSON (`exit_code`, `session_id`, `resume_command`, `taken_over`,
        /// `spawned_by`, `supervision`). Used only when the fixture builds the task itself.
        var fields: [String: JSONValue] = [:]
        /// The task has not been listed yet: no task, so the standalone view draws its loading skeleton and the fixture does
        /// not wait for a task or a principal.
        var loading = false
    }

    static let conversation = "conv"
    static let taskID = "abc12345"

    let config: Config
    let harness: TaskDetailVMTests.SUT
    let coordinator = MainWindowNavigationCoordinatorMock()
    let store = TaskPaneStateStore()
    private let scratch = ScratchDefaults(label: "TopBarIntegrated")
    let window: NSWindow
    private(set) var content: TaskTopBarContent?
    private let tag = TopBarFixtures.tag(TopBarFixtures.Writer(), TopBarIntegratedFixture.conversation)
    private let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
    private let previousEnhanced: Any?
    private var controller: NSHostingController<AnyView>?

    /// Mounts the scenario and waits until the principal and the task toolbar have drawn.
    ///
    /// With an injected `harness` the caller owns every fixture box, stub, provider and the `readChanges` answer: this
    /// initialiser installs none of them and only mounts. `prepare` runs once, after the pane choices are stored and before
    /// the shell is built. Without a harness the fixture builds its own, exactly as before.
    init(_ config: Config, harness injected: TaskDetailVMTests.SUT? = nil, prepare: ((TaskDetailVMTests.SUT) -> Void)? = nil) async {
        _ = NSApplication.shared
        self.config = config
        self.previousEnhanced = NSApplication.shared.accessibilityAttributeValue(enhanced)
        NSApplication.shared.accessibilitySetValue(true, forAttribute: enhanced)
        let harness = injected ?? TaskDetailVMTests().makeSUT(chrome: .standalone)
        self.harness = harness
        if injected == nil {
            // The standalone VM reads stored changes once the pane opens (the chip tests open it) or while a capture settles.
            // The strict mock needs an answer for any key; the key is echoed back, so every lifecycle generation matches. An
            // unreadable listing touches only the Changes tab, which these tests never show: the toolbar, the principal and the
            // Events facts groups do not read it. Same stub as the Summary entry VM tests.
            given(harness.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
                .failure(TaskChangesReadFailure(key: key, outcome: .failed(.unreadable(tool: "harflow-ctl", exitCode: 0, stderr: "unavailable"))))
            }
        }
        let conversation = Self.conversation
        if config.openPane {
            store.setOpenChoice(.open, for: conversation)
            store.setSelectedTab(config.paneTab, for: conversation)
            store.setExpandedGroups(config.expandedGroups, for: conversation)
        }
        if config.closePane, !config.openPane { store.setOpenChoice(.closed, for: conversation) }
        if injected == nil, !config.loading {
            let task = Self.task(config, notices: config.notices)
            harness.detailBox.value = task
            if config.enforcementSnapshot { harness.snapshotBox.value = Self.enforcementSnapshot(of: task) }
        }
        prepare?(harness)
        coordinator.resourceReturnAvailable = config.resourceReturn
        coordinator.selection = .task(conversation)
        coordinator.topBar.setShownConversation(conversation)
        coordinator.topBar.activate(tag)
        let store = store
        coordinator.taskDetailBuilder = { id in
            TaskDetailView(harness.sut, chrome: .standalone, paneBinding: TaskPaneBinding(store: store, conversationID: id),
                           transcriptStyle: .transcript)
                .environment(\.hfReduceMotionOverride, true)
                .id(id)
                .eraseToAnyView()
        }
        let root = MainWindowNavigationView(coordinator, sidebarCollapsed: config.collapsed)
            .defaultAppStorage(scratch.defaults)
            .environment(\.hfReduceMotionOverride, true)
        let controller = NSHostingController(rootView: AnyView(root))
        controller.sceneBridgingOptions = .all
        self.controller = controller
        self.window = M04ToolbarEvidence.makeWindow(controller, size: NSSize(width: config.width, height: config.height))
        // Both appearances are set explicitly: an unset window follows the desktop, so a "light" capture would turn dark.
        window.appearance = NSAppearance(named: config.dark ? .darkAqua : .aqua)
        if config.loading {
            // The skeleton's own accessibility element ("Loading task") is the readiness signal; there is no task or principal.
            await waitUntil(timeout: 10) {
                pump()
                return M04ToolbarEvidence.isPopulated(window) && contentText("Loading task") != nil
            }
            return
        }
        await waitUntil(timeout: 10) {
            pump()
            return harness.sut.task != nil && harness.sut.didSubscribe && M04ToolbarEvidence.isPopulated(window)
        }
        publish()
        await waitUntil(timeout: 10) {
            pump()
            return principalItem != nil
        }
    }

    func close() {
        window.contentViewController = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(previousEnhanced, forAttribute: enhanced)
        controller = nil
        scratch.remove()
    }

    // MARK: Driving

    func pump(times: Int = 1) {
        for _ in 0 ..< times {
            window.layoutIfNeeded()
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// Resizes the window's content and lets the shell and toolbar settle.
    func resize(width: CGFloat) async {
        window.setContentSize(NSSize(width: width, height: config.height))
        var passes = 0
        await waitUntil(timeout: 3) {
            pump()
            passes += 1
            return passes >= 20
        }
    }

    /// Publishes the VM's top bar content, with the scenario's title and badge, through the shell's holder. The VM's own
    /// pane-open state is read each time, so the principal sees what the product's publication would carry.
    ///
    /// This is rendering and layout evidence only. It writes the holder by hand: it does not verify that the production
    /// VM publishes through `TaskDetailRouting`, that the coordinator forwards the write, or that the principal refreshes
    /// on its own. `TaskTopBarTransportTests` and `TaskTopBarHolderTests` cover that transport separately.
    func publish() {
        guard let base = harness.sut.topBarContent else { return }
        let next = TaskTopBarContent(
            title: config.title, badge: config.badge ?? base.badge, metaParts: base.metaParts, isBusy: base.isBusy,
            isPending: base.isPending, paneOpen: base.paneOpen, showsContinuity: base.showsContinuity,
            noticeCount: base.noticeCount, accessText: base.accessText, startedAt: base.startedAt
        )
        content = next
        coordinator.topBar.publish(next, tag: tag)
    }

    /// Replaces the task with one carrying `notices` notices, as a listing update would, and republishes.
    func setNotices(_ notices: Int) {
        let task = Self.task(config, notices: notices)
        harness.detailBox.value = task
        harness.tasksSubject.send([task])
    }

    /// The window content's width and the hosting controller's root view width, as laid out now.
    var contentWidth: CGFloat { window.contentView?.bounds.width ?? 0 }
    var rootWidth: CGFloat { controller?.view.bounds.width ?? 0 }

    /// The band the shell derives from the window's content width.
    var band: TopBarWidthBand { TopBarWidthBand(width: window.contentView?.bounds.width ?? config.width) }

    // MARK: Task

    /// A status snapshot of `task`: the same record (status, notices, supervision) plus the enforcement a `write_in_repo` run
    /// reports, so the inspector has a matching snapshot with enforcement lines.
    static func enforcementSnapshot(of task: TaskInfo) -> TaskInfo {
        var raw = task.raw
        raw["enforcement"] = .object([
            "writes_confined": .bool(true), "direct_commit_commands_denied": .bool(true), "network_access": .string("not_controlled")
        ])
        guard let snapshot = TaskInfo(.object(raw)) else { preconditionFailure("The enforcement snapshot is not a task") }
        return snapshot
    }

    /// The scenario's task: unique notices, a healthy continuity record when asked, a `freedom` when set, and a held
    /// `heavy-build` resource lease when `resourceHeld`. The inline resource card is derived from that lease by the
    /// product's own `TaskDetailResourceContext`, through the real VM.
    static func task(_ config: Config, notices: Int) -> TaskInfo {
        let started = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-90))
        let notes = (0 ..< notices).map { "\"Notice \($0 + 1): the checkout is on the default branch.\"" }.joined(separator: ",")
        let supervision = config.continuity ? """
        ,"supervision":{"owner_state":"alive","process_state":"alive","capture_state":"live","live_input_state":"open",
         "adopted_after_restart":{"at":"2026-10-28T09:10:00Z","observer_kind":"parent_process",
         "previous_server":{"pid":100,"start_time":"Wed Oct 28 09:00:00 2026"},
         "observing_process":{"pid":200,"start_time":"Wed Oct 28 09:10:00 2026"}}}
        """ : ""
        let freedom = config.freedom.map { ",\"freedom\":\"\($0)\"" } ?? ""
        let source = """
        {"task_id":"\(taskID)","backend":"claude","status":"\(config.status)","repo_path":"/repo"\(freedom),
         "started_at":"\(started)","taken_over":false,"live_input":false,"notices":[\(notes)]\(supervision)}
        """
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(source.utf8)), var raw = value.objectValue else {
            preconditionFailure("The integrated top bar fixture task did not decode")
        }
        for (key, field) in config.fields { raw[key] = field }
        if config.resourceHeld {
            raw["phase_slots"] = .array([.object([
                "lease_id": .string("lease-heavy"), "task_id": .string(taskID), "name": .string("heavy-build"),
                "state": .string("held"), "capacity": .number(1),
                "enqueued_at": .string("2026-10-31T00:00:00+00:00"), "granted_at": .string("2026-10-31T00:00:01+00:00")
            ])])
        }
        guard let task = TaskInfo(.object(raw)) else { preconditionFailure("The integrated top bar fixture task is not a task") }
        return task
    }
}
