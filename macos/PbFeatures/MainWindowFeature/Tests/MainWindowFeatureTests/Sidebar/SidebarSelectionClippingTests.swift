import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbCommon
import PbCommonTestMock
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

@MainActor @Suite(.serialized) struct SidebarSelectionClippingTests {
    @Test func givenChildWorkflow_whenSelectedAndContentGrowsThenReopened_thenNativeRowFitsAllLines() async throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        _ = NSApplication.shared
        let state = SelectionClippingState()
        let host = NSHostingView(rootView: SelectionClippingFixture(state: state))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        await waitUntil { host.layoutSubtreeIfNeeded(); return descendants(host).contains { ($0 as? NSOutlineView)?.numberOfRows == 3 } }
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        await waitUntil { host.layoutSubtreeIfNeeded(); return outline.rect(ofRow: 0).height > 50 }
        let fullHeight = outline.rect(ofRow: 0).height
        state.selection = "1"
        await settle(host)
        #expect(outline.rect(ofRow: 1).height >= fullHeight - 1)
        state.detail = false
        await settle(host)
        #expect(outline.rect(ofRow: 1).height < fullHeight - 5)
        state.detail = true
        await settle(host)
        #expect(outline.rect(ofRow: 1).height >= fullHeight - 1)
        state.visible = false
        await settle(host)
        #expect(outline.rect(ofRow: 1).height < fullHeight - 20)
        state.visible = true
        await settle(host)
        #expect(outline.rect(ofRow: 1).height >= fullHeight - 1)
    }

    @Test func givenNestedWorkflowShortcuts_whenSelectionAndPollingReconcile_thenSelectedContentFitsNativeRows() async throws {
        _ = NSApplication.shared
        let harness = SidebarVMTests().makeSUT()
        let now = Date().timeIntervalSince1970
        let parent: [String: JSONValue] = ["workflow_run_id": .string("parent"), "name": .string("Parent"),
            "status": .string("completed"), "created_at": .number(now), "repo_path": .string("/tmp/Code")]
        let child: [String: JSONValue] = ["workflow_run_id": .string("child"), "name": .string("Plan Review Panel"),
            "status": .string("completed"), "created_at": .number(now - 10), "repo_path": .string("/tmp/Code"),
            "parent_link": .object(["workflow_run_id": .string("parent"), "execution_id": .string("invoke")])]
        harness.sut.workflowRuns = [SidebarWorkflowRun(raw: parent), SidebarWorkflowRun(raw: child)]
        harness.sut.expandedExecutionParents.insert("workflow:parent")
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(harness.sut).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: { Text("Detail") }.frame(minWidth: 1000, minHeight: 620).withPresentationContext())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { harness.sut.didDisappear(); window.contentView = nil; window.close() }
        harness.sut.didAppear()
        await harness.sut.waitForPresentation()
        harness.hasListedSubject.send(true)
        harness.sut.recompute()
        await harness.sut.waitForPresentation()
        await settle(host)
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        #expect(harness.sut.sections.flatMap(\.items).contains { $0.id == "workflow-shortcut:parent:child" })
        let twoLine = NSHostingView(rootView: TaskRow(model: TaskRowModel(id: "reference", backend: "workflow",
            title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d"))
            .fixedSize(horizontal: false, vertical: true)
.frame(width: 256))
        let threeLine = NSHostingView(rootView: TaskRow(model: TaskRowModel(id: "reference", backend: "workflow",
            title: "Plan Review Panel", status: .completed, repoName: "Code", ageText: "1d", detailLabel: "Child workflow"))
            .fixedSize(horizontal: false, vertical: true)
.frame(width: 256))
        let minimumHeight = twoLine.fittingSize.height
        let childHeight = threeLine.fittingSize.height
        #expect(childHeight > minimumHeight + 5)
        for selection in [MonitorDestination.workflowRun("child"), .workflowRun("parent"), .workflowRun("child")] {
            harness.sut.didSelect(selection)
            await harness.sut.waitForPresentation()
            for _ in 0 ..< 6 {
                harness.sut.mergeWorkflowHeaders([parent, child])
                harness.sut.recompute()
                await harness.sut.waitForPresentation()
                for _ in 0 ..< 8 {
                    await Task.yield()
                    pumpRunLoop()
                    let rows = outline.selectedRowIndexes
                    #expect(!rows.isEmpty, "Selection must reach the native sidebar")
                    let heights = rows.map { outline.rect(ofRow: $0).height }
                    #expect(heights.allSatisfy { $0 >= minimumHeight - 1 },
                            "Each selected slot must fit independently mounted TaskRow content")
                    if selection == .workflowRun("child") {
                        #expect((heights.max() ?? 0) >= childHeight - 1,
                                "The selected shortcut must fit title, detail and subtitle")
                    }
                }
            }
        }
    }

    @Test func givenNativeSidebarSelection_whenDetailDestinationChanges_thenDisclosureAnimationDoesNotReachDetail() async throws {
        _ = NSApplication.shared
        let harness = SidebarVMTests().makeSUT()
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        let vm = SidebarVM(useCase: harness.useCase, routing: coordinator)
        vm.workflowRuns = [SidebarWorkflowRun(raw: ["workflow_run_id": .string("selection-target"),
            "name": .string("Selected workflow"), "status": .string("completed"), "created_at": .number(Date().timeIntervalSince1970)])]
        let recorder = SelectionTransactionRecorder()
        let host = NSHostingView(rootView: NavigationSplitView {
            SidebarView(vm).navigationSplitViewColumnWidth(min: 240, ideal: 272, max: 340)
        } detail: {
            SelectionTransactionDetail(coordinator: coordinator, recorder: recorder)
        }
.frame(minWidth: 1000, minHeight: 620)
.withPresentationContext())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 620),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { vm.didDisappear(); window.contentView = nil; window.close() }
        vm.didAppear()
        await vm.waitForPresentation()
        harness.hasListedSubject.send(true)
        vm.recompute()
        await vm.waitForPresentation()
        await settle(host)
        let outline = try #require(descendants(host).compactMap { $0 as? NSOutlineView }.first)
        // Drive native selection, including the saved-workflow and history section headers.
        for row in 0 ..< outline.numberOfRows {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            pumpRunLoop()
            if coordinator.selection == .workflowRun("selection-target") { break }
        }
        await waitUntil { pumpRunLoop(); return coordinator.selection == .workflowRun("selection-target") && !recorder.animations.isEmpty }
        #expect(coordinator.selection == .workflowRun("selection-target"), "The native List event must reach real routing")
        #expect(!recorder.animations.isEmpty, "The detail transaction must be observed")
        #expect(recorder.animations.allSatisfy { $0 == nil }, "Disclosure animation must remain scoped to expansion, away from detail navigation")
    }

    private func pumpRunLoop() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005)) }

    private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    private func settle(_ host: NSView) async {
        for _ in 0 ..< 40 {
            try? await Task.sleep(for: .milliseconds(16))
            host.layoutSubtreeIfNeeded()
        }
    }
}

@MainActor @Observable private final class SelectionClippingState {
    var selection: String?
    var detail = true
    var visible = true
}

private struct SelectionClippingFixture: View {
    let state: SelectionClippingState
    var body: some View {
        @Bindable var state = state
        List(selection: $state.selection) {
            ForEach(0 ..< 3) { index in
                SidebarDisclosureRow(isVisible: index != 1 || state.visible, animate: false) {
                    TaskRow(model: TaskRowModel(id: "\(index)", backend: "workflow", title: "Plan Review Panel",
                        status: .completed, repoName: "Code", ageText: "1d",
                        detailLabel: index != 1 || state.detail ? "Child workflow" : nil,
                        indent: 1, guides: [.branch]))
                        .tag("\(index)")
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, 0)
    }
}

@MainActor private final class SelectionTransactionRecorder { var animations: [Animation?] = [] }

private struct SelectionTransactionDetail: View {
    let coordinator: MainWindowCoordinator
    let recorder: SelectionTransactionRecorder
    var body: some View {
        Text(String(describing: coordinator.selection)).transaction { transaction in
            if coordinator.selection == .workflowRun("selection-target") { recorder.animations.append(transaction.animation) }
        }
    }
}
