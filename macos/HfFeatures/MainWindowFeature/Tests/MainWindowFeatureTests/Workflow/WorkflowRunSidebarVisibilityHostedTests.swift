import AppKit
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarVisibilityHostedTests

@MainActor @Suite(.serialized) struct WorkflowRunSidebarVisibilityHostedTests {
    @Test(arguments: ["Graph", "Parallel"], [ColorScheme.light, .dark])
    func givenRegularRun_whenDefaultPaneIsHiddenAndShown_thenContentAndWidthAreRestored(
        mode: String, appearance: ColorScheme
    ) async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-pane-\(mode)-\(UUID().uuidString)")
        scratch.defaults.set(mode, forKey: "workflowViewMode")
        defer { scratch.remove() }
        let size = CGSize(width: 1000, height: 620)
        let fixture = RedesignHost(
            WorkflowView(vm).defaultAppStorage(scratch.defaults).preferredColorScheme(appearance),
            size: size, appearance: appearance
        )
        defer { fixture.close() }
        var captureFailures: [String] = []
        await fixture.settle { fixture.element("Hide right pane") != nil && fixture.element("Original request") != nil }
        await vm.sidebarTask?.value
        await fixture.settle { fixture.element("GOAL") != nil }

        // then: source-available blocks retain their established order and the regular header exposes one toggle.
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(accessibleCount("Hide right pane", in: fixture) == 1)
        try assertDefaultSummary(in: fixture)
        let splitBefore = try #require(runSplit(in: fixture))
        await fixture.settle { abs((runSplit(in: fixture)?.arrangedSubviews.last?.bounds.width ?? 0) - 288) < 1 }
        #expect(abs((splitBefore.arrangedSubviews.last?.bounds.width ?? 0) - 288) < 1,
                "The default pane starts at its 288-point ideal at the approved minimum window")
        if let failure = await captureFailure("expanded", in: fixture, mode: mode, appearance: appearance, size: size) {
            captureFailures.append(failure)
        }
        if mode == "Graph" {
            #expect((fixture.canvasScroll.flatMap { fixture.frame($0)?.width } ?? 0) >= 400,
                    "Graph retains its 400-point canvas floor")
        } else {
            #expect((splitBefore.arrangedSubviews.first?.bounds.width ?? 0) >= 360,
                    "Parallel retains the 360-point lane floor beside the default pane")
        }
        let savedWidth: CGFloat = 320
        splitBefore.setPosition(splitBefore.bounds.width - savedWidth - splitBefore.dividerThickness, ofDividerAt: 0)
        await fixture.settle { abs((runSplit(in: fixture)?.arrangedSubviews.last?.bounds.width ?? 0) - savedWidth) < 1 }
        #expect(abs((runSplit(in: fixture)?.arrangedSubviews.last?.bounds.width ?? 0) - savedWidth) < 1)
        // when: the default child is explicitly removed and later remounted.
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("Show right pane") != nil && fixture.element("workflow-run-inspector") == nil }

        // then: no hidden sidebar content or scroll probe remains in AX or in the native split.
        #expect(fixture.element("workflow-run-inspector") == nil)
        #expect(fixture.element("Original request") == nil)
        #expect(fixture.descendants.compactMap { $0 as? WorkflowRunSidebarScrollProbe }.isEmpty)
        #expect(accessibleCount("Show right pane", in: fixture) == 1)
        let hiddenSplit = runSplit(in: fixture)
        #expect(hiddenSplit == nil || hiddenSplit?.arrangedSubviews.count == 1)
        if mode == "Graph" {
            #expect((fixture.canvasScroll.flatMap { fixture.frame($0)?.width } ?? 0) >= 600,
                    "The Graph canvas expands when the default pane is removed")
        }
        if let failure = await captureFailure("hidden", in: fixture, mode: mode, appearance: appearance, size: size) {
            captureFailures.append(failure)
        }

        #expect(fixture.press(try #require(fixture.element("Show right pane"))))
        await fixture.settle { fixture.element("workflow-run-inspector") != nil && fixture.element("Original request") != nil }
        let restored = try #require(runSplit(in: fixture))
        await fixture.settle { abs((restored.arrangedSubviews.last?.bounds.width ?? 0) - savedWidth) < 1 }
        #expect(abs((restored.arrangedSubviews.last?.bounds.width ?? 0) - savedWidth) < 1)
        if let failure = await captureFailure("expanded-again", in: fixture, mode: mode, appearance: appearance, size: size) {
            captureFailures.append(failure)
        }
        #expect(captureFailures.isEmpty, "Configured native captures failed: \(captureFailures.joined(separator: "; "))")
    }

    @Test
    func givenCollapsedDefaultPane_whenSelectedNodeOverridesIt_thenPriorChoiceReturnsAfterSelection() async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-selection-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("Show right pane") != nil && fixture.element("workflow-run-inspector") == nil }

        // when: a node pane takes precedence, then selection clears.
        vm.selectedNodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        await fixture.settle { fixture.element("workflow-selected-sidebar") != nil }
        #expect(fixture.element("workflow-selected-sidebar") != nil)
        #expect(runSplit(in: fixture)?.arrangedSubviews.count == 2,
                "The selected-node slot mounts the second split child while hiding its default sidebar from AX")
        #expect(fixture.element("Hide right pane") == nil)
        vm.selectedNodeID = nil
        await vm.sidebarTask?.value

        // then: the latent default choice is honored again.
        await fixture.settle { fixture.element("workflow-selected-sidebar") == nil && fixture.element("Show right pane") != nil }
        #expect(fixture.element("workflow-run-inspector") == nil)
        #expect(fixture.element("Show right pane") != nil)
    }

    @Test
    func givenCollapsedDefaultPane_whenRunEntersRecovery_thenRecoveryPaneOverridesHiddenChoice() async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-recovery-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("workflow-run-inspector") == nil }

        // when: public run facts make the existing Graph recovery slot eligible.
        updateRun(vm) {
            $0["status"] = .string("paused")
            $0["interaction_owner"] = .string("monitor")
            $0["input_question"] = .string("Choose how to continue.")
            $0["attention_checkpoint_id"] = .string("checkpoint-1")
            $0["input_decision_id"] = .string("decision-1")
            $0["exhausted_retry_edges"] = .array([.string("retry")])
        }

        // then: the recovery form remains in the default pane, without the ordinary toggle.
        await fixture.settle { fixture.element("Resume") != nil && fixture.element("workflow-run-inspector") != nil }
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Resume") != nil)
        #expect(fixture.element("Hide right pane") == nil)
        #expect(fixture.element("Show right pane") == nil)
    }

    @Test
    func givenHiddenRunPane_whenModeTransfersAndRunChanges_thenChoiceCarriesThenResets() async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-identity-\(UUID().uuidString)")
        scratch.defaults.set("Graph", forKey: "workflowViewMode")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("Show right pane") != nil && fixture.element("workflow-run-inspector") == nil }

        // when: the same run changes to Parallel, then another run and the original run are selected.
        scratch.defaults.set("Parallel", forKey: "workflowViewMode")

        // then: the same run remains collapsed across modes, while a new run starts expanded.
        await fixture.settle { !vm.runGraphVisible && fixture.element("Show right pane") != nil && fixture.element("workflow-run-inspector") == nil }
        #expect(fixture.element("Show right pane") != nil)
        #expect(fixture.element("workflow-run-inspector") == nil)
        updateRun(vm) { $0["workflow_run_id"] = .string("preview-run-next") }
        await fixture.settle { fixture.element("workflow-run-inspector") != nil && fixture.element("Hide right pane") != nil }
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Hide right pane") != nil)
        updateRun(vm) { $0["workflow_run_id"] = .string("preview-run") }
        await fixture.settle { fixture.element("workflow-run-inspector") != nil && fixture.element("Hide right pane") != nil }
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Hide right pane") != nil)
    }

    @Test
    func givenCollapsedDefaultPane_whenPendingApprovalArrivesAndClears_thenPaneStaysOpenAndWidthReturns() async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-approval-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        let split = try #require(runSplit(in: fixture))
        split.setPosition(split.bounds.width - 320 - split.dividerThickness, ofDividerAt: 0)
        await fixture.settle { abs((runSplit(in: fixture)?.arrangedSubviews.last?.bounds.width ?? 0) - 320) < 1 }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("Show right pane") != nil && fixture.element("workflow-run-inspector") == nil }

        // when: the public summary begins reporting an outstanding approval, then clears it.
        updateRun(vm) { $0["approval_summary"] = .object(["pending_count": .number(1)]) }

        // then: protection immediately remounts at the retained user width, without a toggle.
        await fixture.settle { fixture.element("workflow-run-inspector") != nil && fixture.element("Hide right pane") == nil }
        let restored = try #require(runSplit(in: fixture))
        await fixture.settle { abs((restored.arrangedSubviews.last?.bounds.width ?? 0) - 320) < 1 }
        #expect(abs((restored.arrangedSubviews.last?.bounds.width ?? 0) - 320) < 1)
        updateRun(vm) { $0["approval_summary"] = .object(["pending_count": .number(0)]) }
        await fixture.settle { fixture.element("workflow-run-inspector") != nil && fixture.element("Hide right pane") != nil }
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Hide right pane") != nil)
    }

    @Test
    func givenCollapsedDefaultPane_whenGoalDraftBeginsAndEnds_thenEditorAndPaneRemainVisible() async throws {
        // given
        let vm = runWithSidebarContent()
        var raw = vm.selectedRun?.raw ?? [:]
        raw["can_revise_goal"] = .bool(true)
        raw["interaction_owner"] = .string("monitor")
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-goal-draft-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("workflow-run-inspector") == nil && fixture.element("Show right pane") != nil }

        // when: the user brings up goal editing from the run's retained goal control.
        #expect(fixture.press(try #require(fixture.element("Show right pane"))))
        await fixture.settle { fixture.element("Revise goal…") != nil }
        #expect(fixture.press(try #require(fixture.element("Revise goal…"))))

        // then: editing protects the pane, and ending the draft does not restore its old hidden state.
        await fixture.settle { fixture.element("Revised workflow goal") != nil && fixture.element("Hide right pane") == nil }
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Hide right pane") == nil)
        #expect(fixture.element("Revised workflow goal") != nil)
        #expect(fixture.press(try #require(fixture.element("Cancel"))))
        await fixture.settle { fixture.element("Hide right pane") != nil && fixture.element("workflow-run-inspector") != nil }
        #expect(fixture.element("Hide right pane") != nil)
        #expect(fixture.element("workflow-run-inspector") != nil)
    }

    @Test
    func givenRunIsLoadingOrReadFailed_whenHeaderRenders_thenPaneToggleIsAbsent() async throws {
        // given
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-loading-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }

        // when: confirm the ready state, then enter its loading placeholder and read failure.
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.element("Hide right pane") != nil,
                "The ready run offers its visibility action before loading starts")
        vm.initialLoadingKind = "run"
        await fixture.settle { fixture.element("Loading workflow") != nil || fixture.element("Hide right pane") == nil }

        // then: neither transient state offers a half-ready visibility action.
        #expect(fixture.element("Hide right pane") == nil)
        #expect(fixture.element("Show right pane") == nil)
        vm.initialLoadingKind = nil
        vm.initialLoadFailed = true
        await fixture.settle { fixture.element("Hide right pane") == nil && fixture.element("Show right pane") == nil }
        #expect(fixture.element("Hide right pane") == nil)
        #expect(fixture.element("Show right pane") == nil)
    }

    @Test
    func givenHiddenRunWithCallerApprovalOptIn_whenPanelIsAdmitted_thenSidebarStaysMountedWithoutToggle() async throws {
        // given: nested caller_approvals opt-in, with no pending summary count.
        let vm = runWithSidebarContent()
        defer { vm.didDisappear() }
        let scratch = ScratchDefaults(label: "stage3-run-approval-opt-in-\(UUID().uuidString)")
        defer { scratch.remove() }
        let fixture = RedesignHost(WorkflowView(vm).defaultAppStorage(scratch.defaults), size: CGSize(width: 1000, height: 620))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Hide right pane") != nil }
        #expect(fixture.press(try #require(fixture.element("Hide right pane"))))
        await fixture.settle { fixture.element("workflow-run-inspector") == nil }

        // when: caller approval opt-in arrives without pending_count.
        updateRun(vm) {
            $0["status"] = .string("completed")
            $0["settings"] = .object(["caller_approvals": .bool(true)])
        }

        // then: admission mounts the inspector, and neither collapse nor reshow is offered.
        await fixture.settle { fixture.element("workflow-run-inspector") != nil }
        #expect(vm.selectedRun?.raw["approval_summary"] == nil)
        #expect(fixture.element("workflow-run-inspector") != nil)
        #expect(fixture.element("Hide right pane") == nil)
        #expect(fixture.element("Show right pane") == nil)
    }

    func runWithSidebarContent() -> WorkflowVM {
        let vm = WorkflowPreview.make(run: true)
        var raw = vm.selectedRun?.raw ?? [:]
        raw["status"] = .string("running")
        raw.removeValue(forKey: "attention_reason")
        raw["prompt"] = .string("Original request retained in the run.")
        raw["goal"] = .string("Verify the release.")
        raw["goal_revision"] = .number(1)
        raw["technical_plan"] = .string("1. Inspect the change.\n2. Verify the result.")
        raw["created_at"] = .number(1_700_000_000)
        raw["repo_path"] = .string("/tmp/preview-repo")
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        return vm
    }

    func runSplit(in fixture: RedesignHost) -> NSSplitView? {
        fixture.descendants.compactMap { $0 as? NSSplitView }.last(where: \.isVertical)
    }

    func accessibleCount(_ label: String, in fixture: RedesignHost) -> Int {
        var seen = Set<ObjectIdentifier>()
        return fixture.elements(in: fixture.host)
.filter {
            seen.insert(ObjectIdentifier($0)).inserted && fixture.matches($0, label)
        }
.count
    }

    private func updateRun(_ vm: WorkflowVM, _ update: (inout [String: JSONValue]) -> Void) {
        var raw = vm.selectedRun?.raw ?? [:]
        update(&raw)
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
    }

    private func accessibleText(containing fragment: String, in fixture: RedesignHost) -> Bool {
        fixture.elements(in: fixture.host).contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(fragment) == true
            }
        }
    }

    private func assertDefaultSummary(in fixture: RedesignHost) throws {
        #expect(fixture.element("More workflow actions") == nil)
        #expect(accessibleText(containing: "Run started", in: fixture))
        #expect(accessibleText(containing: "preview-repo", in: fixture))
        let goal = fixture.element("GOAL") == nil ? "Verify the release." : "GOAL"
        let labels = ["Original request", goal, "Plan · 1 of 2 completed", "Technical plan"]
        let frames = try labels.map { label in
            let element = try #require(fixture.element(label))
            return try #require(fixture.frame(element))
        }
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $0.minY > $1.minY },
                "The available run summary blocks keep their approved top-to-bottom order")
    }

    private func captureRunPane(
        _ fixture: RedesignHost, state: String, mode: String, appearance: ColorScheme, size: CGSize
    ) async throws {
        guard let directory = HostedCaptureEvidence.directory("HARFLOW_STAGE3_RUN_CAPTURE_DIR") else { return }
        await HostedCaptureEvidence.prepare(fixture.window, dark: appearance == .dark)
        let route = switch (mode, state) {
        case ("Graph", "hidden"): "workflow-run/graph-no-selection"
        case ("Parallel", "hidden"): "workflow-run/parallel-run-pane-collapsed"
        case ("Parallel", _): "workflow-run/parallel-run-pane"
        default: "workflow-run/graph-no-selection"
        }
        let design = HostedCaptureEvidence.Design(
            route: route,
            file: "v2/scripts/states-run-questions.js",
            commit: "70d94ef16173b7f48bc72d4930949f3df0b0b7cd"
        )
        let evidenceState = mode == "Graph" && state == "hidden" ? "interaction-hidden" : state
        try await HostedCaptureEvidence.record(
            directory: directory,
            subject: .init(suite: "stage3-run-pane-\(mode.lowercased())", state: evidenceState,
                           dark: appearance == .dark, size: size, design: design),
            window: fixture.window, host: fixture.host
        )
    }

    private func captureFailure(
        _ state: String, in fixture: RedesignHost, mode: String, appearance: ColorScheme, size: CGSize
    ) async -> String? {
        do {
            try await captureRunPane(fixture, state: state, mode: mode, appearance: appearance, size: size)
            return nil
        } catch {
            return "\(state): \(error)"
        }
    }
}
