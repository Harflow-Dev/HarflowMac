import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowScreenLayoutTests + Builder

extension WorkflowScreenLayoutTests {
    @Test func givenBuilderTaskEmbeddedInEditor_whenRendered_thenItsTaskComposerHasNoDuplicateGlobalComposer() async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string(String(repeating: "a", count: 32)),
            "kind": .string("builder"), "status": .string("running"), "builder_draft": .object(vm.definition),
            "activations": .array([.object(["role": .string("builder"), "tasks": .array([
                .object(["task_id": .string("builder-task")])])])])])
        (vm.useCase as? BuilderSessionUseCase)?.hostedRun = vm.selectedRun?.raw
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in
            AnyView(Text("Embedded builder Activity").accessibilityIdentifier("embedded-builder-activity"))
        }), size: CGSize(width: 1200, height: 800))
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunAwaitingItsTask_whenHosted_thenNoComposerAndStartingLabelIsShown(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: nil)
        #expect(vm.selectedRun?.builderTaskID == nil)
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { _, _ in AnyView(Text("unexpected")) }).preferredColorScheme(appearance),
                                   size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Starting workflow builder…") != nil }
        // then
        #expect(fixture.element("Starting workflow builder…") != nil)
        #expect(fixture.element("unexpected") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenBuilderRunWithTaskAndInjectedView_whenHosted_thenInjectedViewIsShownWithoutOuterComposer(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: "builder-task")
        #expect(vm.selectedRun?.builderTaskID == "builder-task")
        let fixture = RedesignHost(WorkflowView(vm, builderTaskView: { taskID, _ in
            AnyView(Text("Embedded \(taskID)").accessibilityIdentifier("embedded-builder-activity"))
        }).preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("embedded-builder-activity") != nil }
        // then
        #expect(fixture.element("embedded-builder-activity") != nil)
        #expect(fixture.element("Starting workflow builder…") == nil)
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenQualifiedBuilderTask_whenHosted_thenActivityIsRightOfCanvasWithComposerAndInlineFacts(
        size: CGSize, appearance: ColorScheme
    ) async throws {
        // given
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        defer { vm.didDisappear() }
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: "builder-task")
        let task = PaneMocks.running(notices: ["Builder fixture notice"])
        let column = BuilderColumnProbe()
        let fixture = RedesignHost(NavigationSplitView {
            Text("Fixture sidebar").navigationSplitViewColumnWidth(240)
        } detail: {
            WorkflowView(vm, builderTaskView: { _, _ in
                AnyView(TaskDetailView(task, chrome: .builder, transcriptStyle: .transcript)
                    .background(BuilderColumnProbe.Representable(probe: column)))
            })
        }
        .environment(\.hfReduceMotionOverride, true)
        .preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.element("Task facts and reported result") != nil && column.view != nil }
        // then
        #expect(vm.builderRuntime == (vm.useCase as? BuilderSessionUseCase)?.runtimeToken)
        let canvas = try #require(fixture.element("workflow-builder-canvas"))
        let activity = try #require(fixture.element("workflow-builder-activity"))
        #expect(fixture.string(activity, "accessibilityLabel") == "Workflow builder activity")
        let workspace = try #require(fixture.element("workflow-builder-workspace"))
        let canvasFrame = try #require(fixture.frame(canvas))
        let workspaceFrame = try #require(fixture.frame(workspace))
        let columnView = try #require(column.view)
        let columnFrame = columnView.convert(columnView.bounds, to: nil)
        #expect(workspaceFrame.width < size.width, "Budget must use the detail viewport after the navigation sidebar")
        #expect(columnFrame.width > 0 && columnFrame.width <= 461)
        #expect(canvasFrame.minX >= workspaceFrame.minX - 1)
        #expect(abs(columnFrame.maxX - workspaceFrame.maxX) <= 1)
        #expect(abs(columnFrame.minX - canvasFrame.maxX - 1) <= 1)
        #expect(abs(columnFrame.minY - canvasFrame.minY) <= 1)
        #expect(abs(columnFrame.maxY - canvasFrame.maxY) <= 1)
        let composer = try #require(fixture.element("Queue a message…"))
        let composerFrame = try #require(fixture.frame(composer))
        #expect(composerFrame.minX >= columnFrame.minX - 1 && composerFrame.maxX <= columnFrame.maxX + 1)
        #expect(composerFrame.minY >= columnFrame.minY - 1 && composerFrame.maxY <= columnFrame.maxY + 1)
        let overflowing = fixture.descendants.filter { view in
            guard view !== columnView, !view.isHiddenOrHasHiddenAncestor, view.bounds.width > 0 else { return false }
            let frame = view.convert(view.bounds, to: nil)
            return frame.minX >= columnFrame.minX - 1 && frame.minX < columnFrame.maxX - 1 && frame.maxX > columnFrame.maxX + 1
        }
        #expect(overflowing.isEmpty, "Views inside the builder column must not extend past it: \(overflowing.map { String(describing: type(of: $0)) })")
        #expect(fixture.element("Task facts and reported result") != nil)
        #expect(fixture.element("Show event details") == nil)
        #expect(fixture.element("Hide event details") == nil)
        #expect(fixture.element("Close right pane") == nil)
        #expect(!fixture.hasElement(containing: Self.composerLabel))
        let bar = try #require(fixture.element("Standalone nodes, outside the workflow path"))
        let barFrame = try #require(fixture.frame(bar))
        #expect(barFrame.minY >= canvasFrame.maxY - 1)
    }

    @Test(arguments: [CGFloat(460), 300], [ColorScheme.light, .dark])
    func givenBuilderSkeleton_whenLoadingInNarrowColumn_thenScrollDocumentFitsTheColumn(width: CGFloat, appearance: ColorScheme) async throws {
        // given
        let fixture = RedesignHost(TaskLoadingSkeleton(header: nil, chrome: .builder, style: .transcript)
            .environment(\.hfReduceMotionOverride, true)
            .preferredColorScheme(appearance), size: CGSize(width: width, height: 433), appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle { fixture.descendants.contains { ($0 as? NSScrollView)?.documentView != nil } }
        // then
        let scrolls = fixture.descendants.compactMap { $0 as? NSScrollView }.filter { $0.documentView != nil }
        #expect(!scrolls.isEmpty)
        for scroll in scrolls {
            let document = try #require(scroll.documentView)
            #expect(document.frame.width <= width + 1, "Skeleton document \(document.frame.width) must fit the \(width) pt column")
        }
        let overflowing = fixture.descendants.filter { view in
            !view.isHiddenOrHasHiddenAncestor && view.bounds.width > 0 && view.convert(view.bounds, to: nil).maxX > width + 1
        }
        #expect(overflowing.isEmpty, "\(overflowing.map { String(describing: type(of: $0)) })")
    }

    // MARK: Builder feed height (PENDING hosted run)

    enum FeedScenario: CaseIterable, CustomTestStringConvertible {
        case factsCollapsed, factsExpanded, longNotices, bannerAndResourceCard
        var testDescription: String { String(describing: self) }
    }

    @MainActor private struct BuilderMount {
        let vm: WorkflowVM
        let fixture: RedesignHost
        let column: BuilderColumnProbe

        func close() { vm.didDisappear(); fixture.close() }
        var columnFrame: CGRect? { column.view.map { $0.convert($0.bounds, to: nil) } }
        var feedFrame: CGRect? {
            fixture.descendants
.compactMap { $0 as? ActivityFeedNativeTableView }
.first?
.enclosingScrollView
                .map { $0.convert($0.bounds, to: nil) }
        }

        func element(containing text: String) -> NSObject? {
            fixture.descendants.flatMap { fixture.elements(in: $0) }.first { object in
                ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { fixture.string(object, $0)?.contains(text) == true }
            }
        }
    }

    private static let longNotice = "A deliberately long builder notice that wraps over several lines of the narrow activity column "
        + "so that the header has to scroll instead of squeezing the activity feed to nothing."

    private func mountBuilder(_ task: TaskDetailViewModelMock, size: CGSize, appearance: ColorScheme) throws -> BuilderMount {
        let vm = try QualifiedBuilderFixture.makeVM(name: "code-review")
        vm.selectedRun = QualifiedBuilderFixture.builderRun(vm, taskID: "builder-task")
        let column = BuilderColumnProbe()
        let fixture = RedesignHost(NavigationSplitView {
            Text("Fixture sidebar").navigationSplitViewColumnWidth(240)
        } detail: {
            WorkflowView(vm, builderTaskView: { _, _ in
                AnyView(TaskDetailView(task, chrome: .builder, transcriptStyle: .transcript)
                    .background(BuilderColumnProbe.Representable(probe: column)))
            })
        }
        .environment(\.hfReduceMotionOverride, true)
        .preferredColorScheme(appearance), size: size, appearance: appearance)
        return BuilderMount(vm: vm, fixture: fixture, column: column)
    }

    private func scenarioTask(_ scenario: FeedScenario) -> TaskDetailViewModelMock {
        switch scenario {
        case .factsCollapsed, .factsExpanded: PaneMocks.running(notices: [])
        case .longNotices: PaneMocks.running(notices: [Self.longNotice, Self.longNotice, Self.longNotice])
        case .bannerAndResourceCard:
            {
                let task = PaneMocks.running(notices: [])
                task.harflowApprovalBackend = "codex"
                task.resourceContext = TaskResourceContext(
                    title: "Waiting for a resource slot", message: "Another run holds the slot this task needs.",
                    detail: "It starts as soon as the slot is free.", blockers: nil)
                return task
            }()
        }
    }

    struct FeedCase: Sendable, CustomTestStringConvertible {
        let size: CGSize
        let appearance: ColorScheme
        let scenario: FeedScenario
        var testDescription: String { "\(Int(size.width))x\(Int(size.height)) \(appearance) \(scenario)" }

        static let all: [FeedCase] = WorkflowScreenLayoutTests.windowSizes.flatMap { size in
            [ColorScheme.light, .dark].flatMap { appearance in
                FeedScenario.allCases.map { FeedCase(size: size, appearance: appearance, scenario: $0) }
            }
        }
    }

    @Test(arguments: FeedCase.all)
    func givenBuilderColumnScenario_whenHosted_thenFeedKeepsAScrollableHeightAndEverythingIsInsideTheColumn(feedCase: FeedCase) async throws {
        let (size, appearance, scenario) = (feedCase.size, feedCase.appearance, feedCase.scenario)
        // given
        let mount = try mountBuilder(scenarioTask(scenario), size: size, appearance: appearance)
        defer { mount.close() }
        await mount.fixture.settle { mount.fixture.element("Task facts and reported result") != nil && mount.feedFrame != nil }
        // when
        if scenario == .factsExpanded {
            #expect(mount.fixture.press(try #require(mount.fixture.element("Task facts and reported result"))))
            await mount.fixture.settle { mount.feedFrame != nil }
        }
        // then
        let column = try #require(mount.columnFrame)
        let feed = try #require(mount.feedFrame)
        #expect(feed.height >= 79.5, "Feed viewport \(feed.height) must keep at least 80 pt in \(scenario)")
        #expect(feed.minX >= column.minX - 1 && feed.maxX <= column.maxX + 1)
        #expect(feed.minY >= column.minY - 1 && feed.maxY <= column.maxY + 1, "Feed \(feed) must lie inside the column \(column)")
        let header = try #require(mount.fixture.element("workflow-builder-header"))
        let headerFrame = try #require(mount.fixture.frame(header))
        #expect(headerFrame.maxY <= column.maxY + 1 && headerFrame.minY >= column.minY - 1)
        let composer = try #require(mount.fixture.element("Queue a message…"))
        let composerFrame = try #require(mount.fixture.frame(composer))
        #expect(composerFrame.minY >= column.minY - 1 && composerFrame.maxY <= column.maxY + 1)
        let hint = try #require(mount.element(containing: "Send queues"))
        let hintFrame = try #require(mount.fixture.frame(hint))
        #expect(hintFrame.minY >= column.minY - 1 && hintFrame.maxY <= column.maxY + 1)
        if scenario == .bannerAndResourceCard {
            let banner = try #require(mount.element(containing: "needs approval to update this canvas"))
            let card = try #require(mount.element(containing: "Waiting for a resource slot"))
            for object in [banner, card] {
                let frame = try #require(mount.fixture.frame(object))
                #expect(frame.minY >= column.minY - 1 && frame.maxY <= column.maxY + 1)
                #expect(frame.minX >= column.minX - 1 && frame.maxX <= column.maxX + 1)
            }
        }
    }

    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenFactsExpandedWithBannerAndCard_whenHosted_thenTopRegionScrollsAndItsLastControlWorks(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let task = scenarioTask(.bannerAndResourceCard)
        let mount = try mountBuilder(task, size: size, appearance: appearance)
        defer { mount.close() }
        await mount.fixture.settle { mount.fixture.element("Task facts and reported result") != nil && mount.feedFrame != nil }
        #expect(mount.fixture.press(try #require(mount.fixture.element("Task facts and reported result"))))
        await mount.fixture.settle { mount.fixture.element("workflow-builder-top-scroll") != nil }
        // when
        let region = try #require(mount.fixture.element("workflow-builder-top-scroll"))
        let regionFrame = try #require(mount.fixture.frame(region))
        let scroll = try #require(mount.fixture.descendants.compactMap { $0 as? NSScrollView }.first { scroll in
            !(scroll.documentView is ActivityFeedNativeTableView)
                && scroll.convert(scroll.bounds, to: nil).intersects(regionFrame)
                && (scroll.documentView?.frame.height ?? 0) > scroll.contentView.bounds.height + 1
        })
        let document = try #require(scroll.documentView)
        // Layout can still be growing: wait for the document height to hold over two passes, then reveal the last control.
        var previousHeight: CGFloat = -1
        await mount.fixture.settle {
            let height = document.frame.height
            defer { previousHeight = height }
            return height == previousHeight && mount.fixture.element("Open resource slots") != nil
        }
        var previousFrame = CGRect.zero
        var revealed = false
        let deadline = Date().addingTimeInterval(5)
        while !revealed, Date() < deadline {
            await mount.fixture.settle { true }
            guard let control = mount.fixture.element("Open resource slots"), let frame = mount.fixture.frame(control) else { continue }
            document.scrollToVisible(document.convert(frame, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
            mount.fixture.host.layoutSubtreeIfNeeded()
            guard let reached = mount.fixture.frame(control) else { continue }
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            revealed = reached == previousFrame && visible.insetBy(dx: -1, dy: -1).contains(reached)
            previousFrame = reached
        }
        // then
        #expect(document.frame.height > scroll.contentView.bounds.height)
        let last = try #require(mount.fixture.element("Open resource slots"))
        let lastFrame = try #require(mount.fixture.frame(last))
        let clip = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        #expect(lastFrame.minY >= clip.minY - 1 && lastFrame.maxY <= clip.maxY + 1,
                "The last control must be reachable inside the top region's scroll region")
        #expect(mount.fixture.press(last))
        #expect(task.openedResourceSlots == 1)
    }

    /// Measured from leaf accessibility frames, not the header container's union: the gap between the facts
    /// disclosure and the request that opens the column is the top region's padding, so the column starts where the
    /// top region ends rather than after a stretched slot.
    @Test(arguments: windowSizes, [ColorScheme.light, .dark])
    func givenFactsCollapsed_whenHosted_thenColumnStartsRightBelowTheNaturalTopRegion(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let mount = try mountBuilder(PaneMocks.running(notices: []), size: size, appearance: appearance)
        defer { mount.close() }
        await mount.fixture.settle { mount.fixture.element("Task facts and reported result") != nil && mount.element(containing: "Original request") != nil }
        // when
        let column = try #require(mount.columnFrame)
        let disclosure = try #require(mount.fixture.element("Task facts and reported result"))
        let disclosureFrame = try #require(mount.fixture.frame(disclosure))
        let request = try #require(mount.element(containing: "Original request"))
        let requestFrame = try #require(mount.fixture.frame(request))
        // then
        let gap = disclosureFrame.minY - requestFrame.maxY
        #expect(gap >= -1 && gap < 60, "The column must start right below the top region, measured gap \(gap)")
        #expect(column.maxY - disclosureFrame.maxY < 160, "Collapsed top region must keep its natural height, not a stretched slot")
    }

    private static let queuePrompt = "Queue a message…"

    private func queueComposerFrame(in fixture: RedesignHost) -> CGRect? {
        if let element = fixture.element(Self.queuePrompt), let frame = fixture.frame(element) { return frame }
        guard let field = fixture.descendants.compactMap({ $0 as? NSTextField }).first(where: { $0.placeholderString == Self.queuePrompt })
        else { return nil }
        return field.convert(field.bounds, to: nil)
    }

    /// Regression smoke for the non-builder mounts, which must keep their plain VStack column: a feed with height
    /// and a composer wholly inside the window. Exact pixel baselines need a before/after run on the same data.
    @Test(arguments: [TaskDetailChrome.standalone, .group, .embedded], [ColorScheme.light, .dark])
    func givenNonBuilderMount_whenHosted_thenFeedAndComposerKeepTheirColumn(chrome: TaskDetailChrome, appearance: ColorScheme) async throws {
        // given
        let size = CGSize(width: 1000, height: 620)
        let task = PaneMocks.running(notices: [])
        let view: AnyView = chrome == .standalone
            ? AnyView(PaneMocks.standalone(task, store: TaskPaneStateStore()))
            : AnyView(TaskDetailView(task, chrome: chrome, transcriptStyle: .standard))
        let fixture = RedesignHost(view.preferredColorScheme(appearance), size: size, appearance: appearance)
        defer { fixture.close() }
        // when
        await fixture.settle {
            queueComposerFrame(in: fixture) != nil && fixture.descendants.contains { $0 is ActivityFeedNativeTableView }
        }
        // then
        let feed = try #require(fixture.descendants.compactMap { $0 as? ActivityFeedNativeTableView }.first?.enclosingScrollView)
        #expect(feed.bounds.height > 80)
        let composerFrame = try #require(queueComposerFrame(in: fixture))
        #expect(composerFrame.minY >= -1 && composerFrame.maxY <= size.height + 1)
        #expect(fixture.element("workflow-builder-header") == nil)
    }
}

// MARK: - BuilderColumnProbe

/// A test-side view filling the injected builder task view: the column's real layout frame, free of accessibility unions.
@MainActor private final class BuilderColumnProbe {
    var view: NSView?

    struct Representable: NSViewRepresentable {
        let probe: BuilderColumnProbe
        func makeNSView(context _: Context) -> NSView {
            let view = NSView()
            probe.view = view
            return view
        }

        func updateNSView(_: NSView, context _: Context) {}
    }
}
