import AppKit
import Combine
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRecoveryPaneHostedTests

/// Hosted (window-opening) coverage of the Graph recovery pane. Written for the owner's hosted batch; not run by the
/// focused non-hosted gate.
@MainActor @Suite(.serialized) struct WorkflowRecoveryPaneHostedTests {
    @Test(arguments: [CGSize(width: 1000, height: 620), CGSize(width: 1440, height: 900)], [ColorScheme.light, .dark])
    func givenPausedRunInGraph_whenShown_thenRecoveryPaneWithGoalReplacesTheOverlay(size: CGSize, appearance: ColorScheme) async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        vm.selectedRun = pausedRun()
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }

        // when
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults).preferredColorScheme(appearance),
                                   size: size, appearance: appearance)
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil && fixture.element("Recovery options") != nil }

        // then
        #expect(!fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView }, "Graph never draws the floating overlay")
        #expect(fixture.element("Close recovery options") == nil, "The pane has no close")
        #expect(fixture.element("Extra attempts") != nil)
        let split = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical })
        await fixture.settle { abs((split.arrangedSubviews.last?.frame.width ?? 0) - 360) < 1.5 }
        #expect(abs((split.arrangedSubviews.last?.frame.width ?? 0) - 360) < 1.5)
    }

    @Test func givenRecoveryPane_whenResumeIsPressed_thenDispatchesTheExistingResumeControl() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        let vm = harness.sut
        vm.selectedRun = pausedRun()
        vm.instructions = "Try the narrower fix."
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume))

        // then
        await verify(harness.useCase)
            .command(.value("resume"), options: .any, positionals: .value(["recovery-pane-run"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenLongQuestionAndInstructions_whenGraphPaneIsShownAtMinimum_thenResumeAndGoalRemainReachable() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        var raw = pausedRun().raw
        raw["input_question"] = .string(String(repeating: "Decide whether to restore the previous public interface. ", count: 20))
        raw["optional_review_skip_available"] = .bool(true)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.instructions = String(repeating: "Keep existing callers compatible.\n", count: 14)
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil && fixture.recoveryTextView != nil }

        // when
        let editor = try #require(fixture.recoveryTextView)
        let outer = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first {
            $0 !== editor.enclosingScrollView && ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
        })
        let document = try #require(outer.documentView)

        // then — the head stays fixed and the bounded body scrolls to each control.
        #expect(fixture.element("Recovery options") != nil)
        for label in ["Proceed without optional reviewer", "Resume", "Revise goal…"] {
            let control = try #require(fixture.element(label), "Missing: \(label)")
            let frame = try #require(fixture.frame(control))
            document.scrollToVisible(document.convert(frame, from: nil))
            outer.reflectScrolledClipView(outer.contentView)
            fixture.host.layoutSubtreeIfNeeded()
            let viewport = outer.contentView.convert(outer.contentView.bounds, to: nil)
            #expect(viewport.insetBy(dx: -1, dy: -1).intersects(try #require(fixture.frame(control))), "Unreachable: \(label)")
        }
    }

    @Test func givenEligibleRunInGraph_whenBadgeIsActivatedTwiceWithFocusMovedBetween_thenEditorIsFocusedEachTime() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        vm.selectedRun = pausedRun()
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil && fixture.recoveryTextView != nil }
        #expect(!(fixture.window.firstResponder is NSTextView), "Opening the pane automatically never steals focus")

        // when
        let badge = try #require(fixture.element("Paused"))
        #expect(fixture.press(badge))
        await fixture.settle { fixture.window.firstResponder === fixture.recoveryTextView }
        let first = fixture.window.firstResponder === fixture.recoveryTextView
        fixture.window.makeFirstResponder(nil)
        #expect(fixture.press(badge))
        await fixture.settle { fixture.window.firstResponder === fixture.recoveryTextView }

        // then
        #expect(first)
        #expect(fixture.window.firstResponder === fixture.recoveryTextView)
    }

    @Test func givenOpenOverlayInParallel_whenSwitchingToGraphAndBack_thenPaneAndOverlayReplaceEachOtherAndKeepInput() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        vm.selectedRun = pausedRun()
        vm.instructions = "Keep this."
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Parallel")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 700))
        defer { fixture.close() }
        await fixture.settle { fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } }

        // when
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        await fixture.settle {
            !fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } && fixture.element("Resume") != nil
                && fixture.element("Close recovery options") == nil
        }

        // then
        #expect(vm.instructions == "Keep this.")
        #expect(fixture.recoveryTextView?.string == "Keep this.")

        // when — back to Parallel
        scratch.defaults.set("Parallel", forKey: "workflowViewMode")
        await fixture.settle {
            fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } && fixture.element("Close recovery options") != nil
        }

        // then — the overlay is drawn again and Graph's pane is gone, input intact.
        #expect(fixture.element("Recovery options") != nil)
        #expect(vm.instructions == "Keep this.")
    }

    @Test func givenScrolledDefaultSidebar_whenRecoveryBecomesEligibleAndEnds_thenFormIsAtTopAndSavedOriginIsRestored() async throws {
        // given — a long default sidebar (original request) scrolled down while the run is running.
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        var running = pausedRun().raw
        running["status"] = .string("running")
        running["prompt"] = .string(String(repeating: "Original request line.\n", count: 80))
        vm.selectedRun = WorkflowRunModel(raw: running)
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Workflow summary") != nil || fixture.element("Original request") != nil }
        let sidebar = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first {
            ($0.documentView?.bounds.height ?? 0) > $0.contentView.bounds.height
                && $0.convert($0.bounds, to: nil).midX > 600
        })
        sidebar.contentView.scroll(to: NSPoint(x: 0, y: 120))
        sidebar.reflectScrolledClipView(sidebar.contentView)
        let saved = sidebar.contentView.bounds.origin.y

        // when — the run pauses and becomes eligible.
        var paused = running
        paused["status"] = .string("paused")
        vm.selectedRun = WorkflowRunModel(raw: paused)
        WorkflowPreview.synchronizeRun(vm)
        await fixture.settle { fixture.element("Resume") != nil }

        // then — the failure sentence and Resume are at the top of the shared scroll view.
        await fixture.settle { abs(sidebar.contentView.bounds.origin.y) < 1 }
        #expect(abs(sidebar.contentView.bounds.origin.y) < 1)

        // when — eligibility ends.
        vm.selectedRun = WorkflowRunModel(raw: running)
        WorkflowPreview.synchronizeRun(vm)
        await fixture.settle { fixture.element("Resume") == nil }

        // then — the default sidebar's saved origin returns.
        await fixture.settle { abs(sidebar.contentView.bounds.origin.y - saved) < 2 }
        #expect(abs(sidebar.contentView.bounds.origin.y - saved) < 2)
    }

    @Test func givenNeedsInputRunWithApprovalOptIn_whenGraphPaneIsShown_thenMountSmokeShowsPaneAndResume() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        given(harness.useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let vm = harness.sut
        var raw = pausedRun().raw
        raw["status"] = .string("needs_input")
        raw["input_decision_id"] = .string("question-1")
        raw["approval_summary"] = .object(["pending_count": .number(1)])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let scratch = scratch(mode: "Graph")
        defer { scratch.remove(); vm.didDisappear() }

        // when
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Recovery options") != nil }

        // then — a mount smoke only: the pane mounts with approvals opted in, without a controlled approval fixture.
        #expect(fixture.element("Resume") != nil)
    }

    // MARK: Fixtures

    private func scratch(mode: String) -> ScratchDefaults {
        let scratch = ScratchDefaults(label: "WorkflowRecoveryPaneHosted")
        scratch.defaults.set(mode, forKey: "workflowViewMode")
        return scratch
    }

    private func pausedRun() -> WorkflowRunModel {
        WorkflowRunModel(raw: [
            "workflow_run_id": .string("recovery-pane-run"), "name": .string("Upgrade"),
            "status": .string("paused"), "interaction_owner": .string("monitor"),
            "input_question": .string("Draft upgrade PR failed after 3 attempts: tests failed in test_slots.py."),
            "attention_checkpoint_id": .string("attention:recovery-pane-run:checkpoint-1"),
            "input_decision_id": .string("decision-1"),
            "goal": .string("Upgrade the dependency and keep the suite green."), "goal_revision": .number(1),
            "exhausted_retry_edges": .array([.string("retry")]),
            "definition": .object([
                "nodes": .array([.object(["id": .string("work"), "type": .string("agent")]),
                                 .object(["id": .string("check"), "type": .string("agent")])]),
                "connections": .array([.object(["id": .string("retry"), "source": .string("check"), "target": .string("work")])])
            ])
        ])
    }
}
