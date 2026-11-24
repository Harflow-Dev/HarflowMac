import AppKit
import HfTestUtilities
import HfUI
@testable import MenuBarFeature
import MonitorCore
import Observation
import SwiftUI
import Testing

// MARK: - MenuBarLayoutTests

@MainActor @Suite(.serialized) struct MenuBarLayoutTests {
    @Test func givenMenuBarLayoutTokens_whenRead_thenPopoverKeepsTheApprovedSize() {
        // given / when / then
        #expect(HfRadius.Metrics.menuBarPopoverWidth == 380)
        #expect(HfRadius.Metrics.menuBarPopoverHeight == 560)
        #expect(HfRadius.Metrics.menuBarFooterButtonHeight == 34)
    }

    @Test func givenRunningRowData_whenRepositoryIsMissing_thenDetailOmitsIt() {
        // given
        let noActivity = MenuBarRunningRowModel(
            id: "task-1", backend: "codex", title: "Inspect the change", repoName: "",
            startedAt: nil, durationSeconds: 12, activityLine: nil, activityIsMonospaced: false
        )

        // when / then
        #expect(MenuBarRunningRowView.repoLine(noActivity.repoName, hasActivity: false) == nil)
        #expect(MenuBarRunningRowView.repoLine("harflow", hasActivity: false) == "harflow")
        #expect(MenuBarRunningRowView.repoLine("harflow", hasActivity: true) == "· harflow")
    }

    @Test(arguments: [
        ("needs_attention", true, false, true, "Needs Attention"),
        ("needs_input", true, false, true, "Needs Input"),
        ("running", true, true, false, "Running"),
        ("completed", false, false, false, "Completed")
    ])
    func givenWorkflowStatus_whenMapped_thenRowPreservesStatusSemantics(
        rawStatus: String,
        expectedActive: Bool,
        expectedWorking: Bool,
        expectedAttention: Bool,
        expectedLabel: String
    ) throws {
        // given
        let row = try #require(WorkflowMenuBarRow([
            "workflow_run_id": .string("run-1"),
            "name": .string("Review"),
            "status": .string(rawStatus),
            "attention_reason": .string("Needs input from the operator")
        ]))

        // when / then
        #expect(row.isActive == expectedActive)
        #expect(row.isWorking == expectedWorking)
        #expect(row.needsAttention == expectedAttention)
        #expect(row.statusLabel == expectedLabel)
        #expect(row.detail == "Needs input from the operator")
    }

    @Test func givenSettlingWorkflow_whenMapped_thenItRemainsActiveAndUsesSettlingCopy() throws {
        // given
        let row = try #require(WorkflowMenuBarRow([
            "workflow_run_id": .string("run-1"),
            "name": .string("Review"),
            "status": .string("completed"),
            "settling": .bool(true)
        ]))

        // when / then
        #expect(row.isActive)
        #expect(row.isWorking)
        #expect(!row.isRunning)
        #expect(row.statusLabel == "Settling")
    }

    @Test func givenIdleMenuBar_whenHosted_thenEmptyHeaderAndFooterActionsRemainAccessible() async throws {
        // given
        let model = MenuBarHostedModel()
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Nothing running") != nil }

        // then
        #expect(fixture.matching("Nothing running").count == 1)
        #expect(fixture.element("Nothing running.") == nil)
        #expect(fixture.element("New session") != nil)
        #expect(fixture.element("Open Harflow") != nil)
        #expect(fixture.element("⌘O") == nil)
        #expect(model.appearCount == 1)
        let newSession = try #require(fixture.element("New session"))
        let openMonitor = try #require(fixture.element("Open Harflow"))
        #expect(fixture.press(newSession))
        await waitUntil { model.newSessionCount == 1 }
        #expect(fixture.press(openMonitor))
        await waitUntil { model.openMonitorCount == 1 }
        #expect(model.newSessionCount == 1)
        #expect(model.openMonitorCount == 1)
    }

    @Test func givenBusyMenuBar_whenHosted_thenSectionsRemainInWorkflowRunningRecentOrder() async throws {
        // given
        let model = MenuBarHostedModel.busy
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Workflows") != nil && fixture.element("Running") != nil && fixture.element("Recent") != nil }

        // then
        let labels = try ["Workflows", "Running", "Recent"].map { try #require(fixture.element($0)) }
        let frames = try labels.map { element in
            try #require(fixture.screenFrame(element))
        }
        #expect(frames[0].maxY > frames[1].maxY)
        #expect(frames[1].maxY > frames[2].maxY)
        // SwiftUI exposes each composed row as one native AX aggregate rather than one node per
        // Text child; match the aggregate's public label/value while retaining row evidence.
        #expect(fixture.containsText("code-review"))
        #expect(fixture.containsText("Fix the login bug"))
        #expect(fixture.containsText("Draft release notes"))
        await waitUntil { model.runningAppearIDs == ["task-1"] }
        #expect(model.runningDisappearIDs.isEmpty)
        fixture.close()
        await waitUntil { model.runningDisappearIDs == ["task-1"] }
    }

    @Test func givenLoadingCounts_whenHosted_thenAttentionAndWorkflowSuffixStayHidden() async throws {
        // given
        let model = MenuBarHostedModel(taskCountsLoading: true, workflowCountsLoading: true)
        model.workflowActiveCount = 3
        model.workflowAttentionCount = 2
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Counting running agents…") != nil }

        // then
        #expect(fixture.element("Counting workflows…") != nil)
        #expect(fixture.element("2 need attention") == nil)
        #expect(fixture.element("· 3 workflows active") == nil)
        #expect(fixture.element("Nothing running") == nil)
    }

    @Test(arguments: [
        (1, 1, "1 needs attention", "· 1 workflow active"),
        (2, 2, "2 need attention", "· 2 workflows active")
    ])
    func givenLoadedCounts_whenHosted_thenAttentionAndWorkflowSuffixUseCorrectGrammar(
        attentionCount: Int, workflowCount: Int, attentionText: String, workflowText: String
    ) async throws {
        // given
        let model = MenuBarHostedModel(runningCount: 1)
        model.workflowActiveCount = workflowCount
        model.workflowAttentionCount = attentionCount
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.containsText(attentionText) && fixture.containsText(workflowText) }

        // then — loaded catalog counts are rendered with their existing meaning and grammar.
        #expect(fixture.containsText(attentionText))
        #expect(fixture.containsText(workflowText))
    }

    @Test(arguments: [
        (MenuBarRuntimeCard.setupRequired, "Finish setting up Harflow to see your work."),
        (.preparing, "Preparing the exact paired runtime. This can take a few minutes."),
        (.failed(message: "Package verification failed."), "The managed runtime is unavailable. Try again to prepare it.")
    ])
    func givenARuntimeCard_whenHosted_thenItReplacesTheSectionsAndTheConnectionRow(card: MenuBarRuntimeCard, text: String) async throws {
        // given
        let model = MenuBarHostedModel.busy
        model.runtimeCard = card
        model.canStartNewSession = false
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.containsText(text) }

        // then — one block between the header and the footer: no sections, no dot row, "+" disabled.
        #expect(fixture.containsText(card.subline))
        #expect(!fixture.containsText("Workflows"))
        #expect(!fixture.containsText("Running"))
        #expect(!fixture.containsText("harflow connected"))
        let newSession = try #require(fixture.element("New session"))
        _ = fixture.press(newSession)
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(model.newSessionCount == 0)
    }

    @Test func givenLongHeaderAndWorkflowCount_whenHosted_thenFooterTargetsRemainVisible() async throws {
        // given
        let model = MenuBarHostedModel(runningCount: 123)
        model.workflowActiveCount = 4
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.containsText("123 running") && fixture.containsText("4 workflows active") }

        // then — long count text must not displace either existing footer action.
        let newSession = try #require(fixture.element("New session"))
        let openMonitor = try #require(fixture.element("Open Harflow"))
        let contentFrame = try #require(fixture.contentScreenFrame)
        let newSessionFrame = try #require(fixture.screenFrame(newSession))
        let openMonitorFrame = try #require(fixture.screenFrame(openMonitor))
        #expect(contentFrame.contains(newSessionFrame))
        #expect(contentFrame.contains(openMonitorFrame))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "o",
            charactersIgnoringModifiers: "o", isARepeat: false, keyCode: 31
        ))
        #expect(fixture.window.performKeyEquivalent(with: event))
        await waitUntil { model.openMonitorCount == 1 }
    }

    @Test func givenWorkflowStatusErrorWithNoRows_whenHosted_thenOneWorkflowsLabelSitsAboveTheError() async throws {
        // given
        let model = MenuBarHostedModel(runningCount: 0)
        model.workflowRows = []
        model.workflowStatusError = "Workflow status unavailable"
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.element("Workflows") != nil && fixture.containsText("Workflow status unavailable") }

        // then
        #expect(fixture.matching("Workflows").count == 1)
        let label = try #require(fixture.element("Workflows"))
        let labelFrame = try #require(fixture.screenFrame(label))
        let errorFrame = try #require(fixture.firstFrame(containing: "Workflow status unavailable"))
        #expect(labelFrame.maxY > errorFrame.maxY)
    }

    @Test func givenListAndWorkflowNotices_whenHosted_thenOriginalMessagesRemainAndListNoticePrecedesSections() async throws {
        // given
        let model = MenuBarHostedModel(runningCount: 1)
        model.refreshNote = MenuBarRefreshNote(message: "harflow-ctl task-list-page exited 1 without a JSON answer.")
        model.workflowStatusError = "Workflow status unavailable"
        model.workflowRows = [WorkflowMenuBarRow([
            "workflow_run_id": .string("run-1"), "name": .string("code-review"), "status": .string("running")
        ])!]
        model.workflowActiveCount = 1
        let fixture = MenuBarHostedFixture(model: model)
        defer { fixture.close() }

        // when
        await fixture.settle { fixture.containsText("without a JSON answer") && fixture.containsText("Workflows") }

        // then — notices stay durable and retain their original wording.
        #expect(fixture.containsText("Couldn't refresh your work"))
        #expect(fixture.containsText("harflow-ctl task-list-page exited 1 without a JSON answer."))
        #expect(fixture.containsText("Workflow status unavailable"))
        let noticeFrame = try #require(fixture.firstFrame(containing: "without a JSON answer"))
        let workflowsElement = try #require(fixture.element("Workflows"))
        let workflowsFrame = try #require(fixture.screenFrame(workflowsElement))
        #expect(noticeFrame.maxY > workflowsFrame.maxY)
        let retry = try #require(fixture.element("Retry"))
        #expect(fixture.press(retry))
        await waitUntil { model.retryCount == 1 }
        #expect(model.newSessionCount == 0)
        #expect(model.openMonitorCount == 0)
    }
}

// MARK: - MenuBarHostedFixture

@MainActor private final class MenuBarHostedFixture {
    let controller: NSHostingController<MenuBarView<MenuBarHostedModel>>
    let window: NSWindow
    private let previousEnhancedInterface: Any?
    private var isClosed = false

    init(model: MenuBarHostedModel) {
        _ = NSApplication.shared
        let size = CGSize(
            width: HfRadius.Metrics.menuBarPopoverWidth,
            height: HfRadius.Metrics.menuBarPopoverHeight
        )
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(
            true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        self.controller = NSHostingController(rootView: MenuBarView(model))
        controller.sceneBridgingOptions = .all
        self.window = NSWindow(
            contentRect: CGRect(
                x: 0, y: 0,
                width: HfRadius.Metrics.menuBarPopoverWidth,
                height: HfRadius.Metrics.menuBarPopoverHeight
            ),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        window.setContentSize(size)
        window.contentView?.setFrameSize(size)
        controller.view.setFrameSize(size)
        window.orderFront(nil)
    }

    var descendants: [NSView] { views(controller.view) }

    /// The content view's bounds in screen coordinates, the space `screenFrame` uses.
    var contentScreenFrame: CGRect? {
        guard let contentView = window.contentView else { return nil }
        return window.convertToScreen(contentView.convert(contentView.bounds, to: nil))
    }

    func settle(_ predicate: @escaping () -> Bool) async {
        await waitUntil {
            window.layoutIfNeeded()
            let size = CGSize(
                width: HfRadius.Metrics.menuBarPopoverWidth,
                height: HfRadius.Metrics.menuBarPopoverHeight
            )
            window.contentView?.setFrameSize(size)
            controller.view.setFrameSize(size)
            controller.view.layoutSubtreeIfNeeded()
            return predicate()
        }
    }

    func matching(_ label: String) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return descendants.flatMap { elements(in: $0) }.filter { object in
            guard seen.insert(ObjectIdentifier(object)).inserted else { return false }
            return ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
                string(object, key) == label
            }
        }
    }

    func element(_ label: String) -> NSObject? { matching(label).first }

    func containsText(_ fragment: String) -> Bool {
        descendants.flatMap { elements(in: $0) }.contains { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
                string(object, key)?.contains(fragment) == true
            }
        }
    }

    func firstFrame(containing fragment: String) -> CGRect? {
        descendants.flatMap { elements(in: $0) }
.first { object in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { key in
                string(object, key)?.contains(fragment) == true
            }
        }
.flatMap(screenFrame)
    }

    /// The element's frame in screen coordinates, shared by native views and accessibility elements.
    func screenFrame(_ object: NSObject) -> CGRect? {
        if let view = object as? NSView {
            guard let viewWindow = view.window else { return nil }
            return viewWindow.convertToScreen(view.convert(view.bounds, to: nil))
        }
        if let accessible = object as? any NSAccessibilityProtocol {
            return accessible.accessibilityFrame()
        }
        let selector = NSSelectorFromString("accessibilityFrame")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return nil }
        typealias Frame = @convention(c) (AnyObject, Selector) -> CGRect
        let implementation = unsafeBitCast(method, to: Frame.self)
        return implementation(object, selector)
    }

    func press(_ object: NSObject) -> Bool {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector), let method = object.method(for: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(method, to: Press.self)
        return implementation(object, selector)
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        window.contentViewController = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(
            previousEnhancedInterface,
            forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
    }

    private func string(_ object: NSObject, _ property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    private func elements(in object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector),
              let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject]
        else { return [object] }
        return [object] + children.flatMap { elements(in: $0) }
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
}

// MARK: - MenuBarHostedModel

@MainActor @Observable private final class MenuBarHostedModel: MenuBarViewModel {
    var runningRows: [MenuBarRunningRowModel] = []
    var recentGroups: [ParallelGroup] = []
    var recentTasks: [TaskRowModel] = []
    var isConnected = true
    var connectionLine = "connected · harflow-ctl"
    var runningCount: Int
    var canStartNewSession = true
    var taskCountsLoading: Bool
    var workflowCountsLoading: Bool
    var workflowRows: [WorkflowMenuBarRow] = []
    var workflowActiveCount = 0
    var workflowAttentionCount = 0
    var workflowStatusError: String?
    var headerSubline = "harflow connected"
    var runtimeCard: MenuBarRuntimeCard?
    var refreshNote: MenuBarRefreshNote?
    var retryCount = 0
    var appearCount = 0
    var newSessionCount = 0
    var openMonitorCount = 0
    var runningAppearIDs: [String] = []
    var runningDisappearIDs: [String] = []

    init(
        runningCount: Int = 0,
        taskCountsLoading: Bool = false,
        workflowCountsLoading: Bool = false
    ) {
        self.runningCount = runningCount
        self.taskCountsLoading = taskCountsLoading
        self.workflowCountsLoading = workflowCountsLoading
    }

    static var busy: MenuBarHostedModel {
        let model = MenuBarHostedModel(runningCount: 1)
        model.runningRows = [MenuBarRunningRowModel(
            id: "task-1", backend: "claude", title: "Fix the login bug", repoName: "harflow",
            startedAt: .now, durationSeconds: nil, activityLine: "grep login", activityIsMonospaced: true
        )]
        model.recentTasks = [TaskRowModel(
            id: "recent-1", backend: "codex", title: "Draft release notes", status: .completed,
            repoName: "harflow", ageText: "3h"
        )]
        model.workflowRows = [WorkflowMenuBarRow([
            "workflow_run_id": .string("run-1"), "name": .string("code-review"), "status": .string("running")
        ])!]
        model.workflowActiveCount = 1
        return model
    }

    func didAppear() { appearCount += 1 }
    func didDisappear() {}
    func didDisappearStatusItem() {}
    func didSelectWorkflow(_: String) {}
    func didAppearRunningRow(_ id: String) { runningAppearIDs.append(id) }
    func didDisappearRunningRow(_ id: String) { runningDisappearIDs.append(id) }
    func didSelectRunningTask(_: String) {}
    func didSelectRecentTask(_: String) {}
    func didSelectGroup(_: String) {}
    func didTapOpenMonitor() { openMonitorCount += 1 }
    func didTapNewSession() { newSessionCount += 1 }
    func didCaptureWindowOpener(_: @escaping () -> Void) {}
    func didTapRetryRefresh() { retryCount += 1 }
    func didEditAnswer(_: String, text _: String) {}
    func didSubmitAnswer(_: String) {}
}
