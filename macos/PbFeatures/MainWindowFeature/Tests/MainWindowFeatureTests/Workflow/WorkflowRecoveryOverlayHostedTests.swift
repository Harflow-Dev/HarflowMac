import AppKit
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowRecoveryOverlayHostedTests

@MainActor @Suite(.serialized) struct WorkflowRecoveryOverlayHostedTests {
    @Test func givenEligibleWorkflow_whenOverlayCloses_thenDiagnosticsGeometryAndInputRemainStable() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string("overlay-run"),
            "status": .string("needs_attention"),
            "interaction_owner": .string("monitor"),
            "attention_reason": .string("Choose the next approach.")
        ]
        raw["status"] = .string("needs_attention")
        raw["interaction_owner"] = .string("monitor")
        raw["input_question"] = .string("Choose the next approach.")
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.instructions = "Keep the current implementation."
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 1000, height: 700))
        defer { fixture.close() }
        await fixture.settle {
            fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView }
                && fixture.element("Close recovery options") != nil
        }
        let panel = try #require(fixture.descendants.compactMap { $0 as? WorkflowRecoveryPanelRootView }.first)
        #expect(matchingElements(in: fixture, label: "Recovery options").count == 1)
        let splitFramesBefore = splitFrames(in: fixture)
        let hostBoundsBefore = fixture.host.bounds
        let inputBefore = vm.instructions
        #expect(!(fixture.window.firstResponder is NSTextView), "Automatic opening must not steal editor focus")
        #expect(matchingElements(in: fixture, label: "Choose the next approach.").count == 1,
                "The open panel suppresses only the duplicate reason announcement")
        let zoom = try #require(fixture.element("Zoom in"))
        let zoomFrame = try #require(fixture.frame(zoom))
        let panelFrame = try #require(fixture.frame(panel))
        #expect(!zoomFrame.intersects(panelFrame), "Underlying canvas action remains outside the panel")
        #expect(fixture.press(zoom))

        // when
        let close = try #require(fixture.element("Close recovery options"))
        #expect(fixture.press(close))
        await fixture.settle { !fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } }

        // then — visibility is presentation-only and does not affect diagnostics or VM input.
        #expect(fixture.host.bounds == hostBoundsBefore)
        #expect(splitFrames(in: fixture) == splitFramesBefore)
        #expect(vm.instructions == inputBefore)
        #expect(vm.selectedRun?.id == raw["workflow_run_id"]?.stringValue)
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
        #expect(!panel.keyboard.isAttached(panelRoot: panel))

        // when — the eligible status badge reopens the same panel without changing pane layout.
        let badge = try #require(fixture.element("Needs attention"))
        #expect(fixture.press(badge))
        await fixture.settle {
            fixture.element("Close recovery options") != nil
                && fixture.window.firstResponder === fixture.recoveryTextView
        }
        #expect(splitFrames(in: fixture) == splitFramesBefore)
        #expect(fixture.window.firstResponder === fixture.recoveryTextView,
                "Explicit badge opening requests focus for the actual native editor")
    }

    @Test func givenLongRecoveryQuestionInNarrowWorkflow_whenOverlayIsShown_thenQuestionAndActionsRemainReachable() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        var raw: [String: JSONValue] = [
            "workflow_run_id": .string("long-overlay-run"),
            "status": .string("needs_input"),
            "interaction_owner": .string("monitor")
        ]
        raw["status"] = .string("needs_input")
        raw["execution_contract"] = .string("delegation")
        raw["interaction_owner"] = .string("monitor")
        raw["input_decision_id"] = .string("question")
        raw["input_question"] = .string(String(repeating: "Choose whether to preserve the existing workflow interface before continuing. ", count: 14))
        raw["exhausted_retry_edges"] = .array([.object(["edge_id": .string("retry")])])
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.instructions = String(repeating: "Preserve existing behavior.\n", count: 8)
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 420, height: 420))
        defer { fixture.close() }
        await fixture.settle {
            fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView }
                && fixture.element("Resume") != nil
        }

        // when
        let panel = try #require(fixture.descendants.compactMap { $0 as? WorkflowRecoveryPanelRootView }.first)
        let panelGroups = matchingElements(in: fixture, label: "Recovery options")
        #expect(panelGroups.count == 1, "The mounted panel has one owned accessibility group")
        #expect(matchingElements(in: fixture, label: raw["input_question"]?.stringValue ?? "").count == 1,
                "The full recovery question remains available across the native hosting boundary")
        let scrolls = fixture.descendants
.filter { $0 !== panel && $0.isDescendant(of: panel) }
            .compactMap { $0 as? NSScrollView }
        let outer = try #require(scrolls.first)
        let document = try #require(outer.documentView)
        let resume = try #require(fixture.element("Resume"))
        let close = try #require(fixture.element("Close recovery options"))

        // then — bounded native scrolling keeps the complete editor and terminal actions usable.
        #expect(outer.bounds.height <= 420 - 2 * PbRadius.Metrics.recoveryPanelInset + 1)
        #expect(fixture.recoveryTextView?.string == vm.instructions)
        #expect(fixture.frame(resume) != nil)
        #expect(fixture.frame(close) != nil)
        let resumeFrame = try #require(fixture.frame(resume))
        document.scrollToVisible(document.convert(resumeFrame, from: nil))
        outer.reflectScrolledClipView(outer.contentView)
        fixture.host.layoutSubtreeIfNeeded()
        let visiblePanel = outer.contentView.convert(outer.contentView.bounds, to: nil)
        #expect(visiblePanel.intersects(try #require(fixture.frame(resume))),
                "Resume remains reachable by the panel's actual native scroll view")
        #expect(fixture.press(close))
        #expect(vm.instructions.contains("Preserve existing behavior."))
    }

    @Test func givenLongDiagnosticsHistory_whenOverlayIsOpen_thenNativeDiagnosticsScrollAndActionRemainAvailable() async throws {
        // given — only reported decision history is used; no synthetic UI-only content.
        let vm = WorkflowPreview.make(run: true)
        let longReason = String(repeating: "The scheduler retained this reported decision diagnostic. ", count: 12)
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("diagnostic-run"), "status": .string("needs_attention"),
            "interaction_owner": .string("monitor"),
            "attention_reason": .string("Choose the next approach."),
            "input_question": .string("Choose the next approach."),
            "decisions": .array((0 ..< 12).map { _ in .object(["reason": .string(longReason)]) }),
            "pending": .array((0 ..< 80).map { _ in .object(["decision_attempts": .number(2)]) }),
            "definition": .object(["max_decision_attempts": .number(3)])
        ])
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 1000, height: 700))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Close recovery options") != nil }
        let panel = try #require(fixture.descendants.compactMap { $0 as? WorkflowRecoveryPanelRootView }.first)
        let paneSplit = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { !$0.isVertical })
        let diagnostics = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first {
            !$0.isDescendant(of: paneSplit) && !$0.isDescendant(of: panel)
        })
        let document = try #require(diagnostics.documentView)
        let diagnosticsFrame = try #require(fixture.frame(diagnostics))
        let panelFrame = try #require(fixture.frame(panel))

        // when / then — the real diagnostics viewport overflows and its existing action remains hit-testable.
        #expect(document.bounds.height > diagnostics.contentView.bounds.height)
        #expect(diagnosticsFrame.minY >= panelFrame.maxY - 1, "Diagnostics remain above the floating panel")
        #expect(!diagnosticsFrame.intersects(panelFrame))
        let showMore = try #require(fixture.element("Show more"))
        #expect(fixture.press(showMore))
    }

    @Test func givenMountedWorkflowPanel_whenRealEditorReceivesEscape_thenItClosesAndRetainsInput() async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("escape-run"), "status": .string("needs_attention"),
            "interaction_owner": .string("monitor"), "input_question": .string("Choose a path.")
        ])
        vm.instructions = "Keep this answer exactly."
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 900, height: 620))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } }
        let panel = try #require(fixture.descendants.compactMap { $0 as? WorkflowRecoveryPanelRootView }.first)
        let editor = try #require(fixture.recoveryTextView)
        #expect(fixture.window.makeFirstResponder(editor))
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53
        ))

        // when
        #expect(panel.keyboard.handle(event) == nil)
        await fixture.settle { !fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView } }

        // then
        #expect(vm.instructions == "Keep this answer exactly.")
        #expect(!panel.keyboard.isAttached(panelRoot: panel))
    }

    @Test func givenBuilderRun_whenWorkflowLoads_thenRecoveryOverlayIsAbsent() async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        vm.selectedRun = WorkflowRunModel(raw: [
            "workflow_run_id": .string("builder-run"), "kind": .string("builder"),
            "status": .string("needs_attention"), "interaction_owner": .string("monitor"),
            "input_question": .string("Builder question")
        ])
        let fixture = RedesignHost(WorkflowView(vm), size: CGSize(width: 900, height: 600))
        defer { vm.didDisappear(); fixture.close() }

        // when / then
        await fixture.settle { fixture.element("Workflow steps") != nil }
        #expect(!fixture.descendants.contains { $0 is WorkflowRecoveryPanelRootView })
        #expect(fixture.element("Close recovery options") == nil)
    }

    private func splitFrames(in fixture: RedesignHost) -> [CGRect] {
        fixture.descendants
.compactMap { view -> CGRect? in
            guard view is NSSplitView else { return nil }
            return fixture.frame(view)
        }
.sorted {
            if $0.minX != $1.minX { return $0.minX < $1.minX }
            if $0.minY != $1.minY { return $0.minY < $1.minY }
            if $0.width != $1.width { return $0.width < $1.width }
            return $0.height < $1.height
        }
    }

    private func matchingElements(in fixture: RedesignHost, label: String) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { object in
            guard seen.insert(ObjectIdentifier(object)).inserted else { return false }
            return ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { property in
                fixture.string(object, property) == label
            }
        }
    }
}
