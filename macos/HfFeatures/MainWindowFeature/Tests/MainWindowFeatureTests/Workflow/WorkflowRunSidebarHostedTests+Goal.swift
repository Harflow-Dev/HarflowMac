import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests goal block

extension WorkflowRunSidebarHostedTests {
    /// Where the goal block is mounted: the default run sidebar, or the selected worker node's pane.
    enum GoalSurface: CaseIterable { case defaultSidebar, selectedPane }

    private static let size = CGSize(width: 1440, height: 900)

    private func goalFixture(surface: GoalSurface, appearance: ColorScheme, run extra: [String: JSONValue])
        throws -> (vm: WorkflowVM, fixture: RedesignHost) {
        let vm = WorkflowPreview.make(run: true)
        let nodeID = try #require(vm.nodes.first { $0.type == "agent" }?.id)
        var raw = try #require(vm.selectedRun?.raw)
        raw["status"] = .string("running")
        raw["goal"] = .string("Verify the release.")
        raw["goal_revision"] = .number(1)
        raw["interaction_owner"] = .string("monitor")
        raw["can_revise_goal"] = .bool(true)
        raw["activations"] = .array([.object([
            "id": .string("attempt-0"), "role": .string("node"), "node_id": .string(nodeID), "status": .string("running"),
            "tasks": .array([.object(["task_id": .string("task-0"), "status": .string("running")])])
        ])])
        for (key, value) in extra { raw[key] = value }
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: Self.size)
        if surface == .selectedPane { vm.selectedNodeID = nodeID }
        return (vm, fixture)
    }

    /// The accessibility elements inside the surface that mounts the goal block, so a lookup never matches the other surface.
    private func goalElements(_ surface: GoalSurface, in fixture: RedesignHost) -> [NSObject] {
        let identifier = surface == .selectedPane ? "workflow-selected-sidebar" : "workflow-run-inspector"
        guard let container = fixture.element(identifier), let bounds = fixture.frame(container) else { return [] }
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter { element in
            guard let frame = fixture.frame(element), frame != .zero else { return false }
            return bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func goalLabels(_ surface: GoalSurface, in fixture: RedesignHost) -> [String] {
        goalElements(surface, in: fixture).flatMap { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].compactMap { fixture.string(element, $0) }
        }
    }

    private func goalContains(_ text: String, _ surface: GoalSurface, in fixture: RedesignHost) -> Bool {
        goalLabels(surface, in: fixture).contains { $0.contains(text) }
    }

    private func accessibilityEnabledBySelector(_ element: NSObject) -> Bool? {
        let selector = NSSelectorFromString("isAccessibilityEnabled")
        guard element.responds(to: selector) else { return nil }
        typealias Getter = @convention(c) (AnyObject, Selector) -> Bool
        return unsafeBitCast(element.method(for: selector), to: Getter.self)(element, selector)
    }

    private func accessibilityEnabledByKVC(_ element: NSObject) -> Bool? {
        guard element.responds(to: NSSelectorFromString("isAccessibilityEnabled"))
            || element.responds(to: NSSelectorFromString("accessibilityEnabled")) else { return nil }
        return (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue
    }

    private func goalElement(_ label: String, _ surface: GoalSurface, in fixture: RedesignHost) -> NSObject? {
        goalElements(surface, in: fixture).first { fixture.matches($0, label) }
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenActiveRun_whenGoalBlockRenders_thenLabelTextAssessmentAndReviseLinkShowExpanded(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: [:])
        defer { vm.didDisappear(); fixture.close() }
        // when
        await fixture.settle { goalContains("Assessment: in progress", surface, in: fixture) }
        // then
        #expect(goalContains("GOAL", surface, in: fixture))
        #expect(goalContains("Verify the release.", surface, in: fixture), "The goal text shows without opening a disclosure")
        #expect(goalContains("Revise goal…", surface, in: fixture))
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenRevisableRun_whenRevisePressed_thenFormShowsLabelCaptionAndActions(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: [
            "goal_revision": .number(2),
            "interaction_state": .object(["owner": .string("monitor"), "caller_state": .string("attached"),
                                          "monitor_available": .bool(true), "reason": .string(""),
                                          "responders": .array([.string("caller"), .string("monitor")])])
        ])
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { goalElement("Revise goal…", surface, in: fixture) != nil }
        // when
        vm.beginGoalDraft(run: try #require(vm.selectedRun))
        await fixture.settle { goalElement("Save goal", surface, in: fixture) != nil }
        // then
        #expect(goalContains("Goal · revision 2", surface, in: fixture))
        #expect(goalContains("The original caller can also answer. Whichever answers first is used.", surface, in: fixture))
        #expect(goalElement("Revised workflow goal", surface, in: fixture) != nil)
        #expect(goalElement("Cancel", surface, in: fixture) != nil)
        #expect(goalElement("Save goal", surface, in: fixture) != nil)
        #expect(vm.goalDraft?.text == "Verify the release.")
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenFailedSave_whenFormShows_thenAlertKeepsTheDraft(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: [:])
        defer { vm.didDisappear(); fixture.close() }
        vm.beginGoalDraft(run: try #require(vm.selectedRun))
        // when
        vm.goalRevisionError = "The run did not accept the new goal."
        await fixture.settle { goalContains("Your draft is preserved.", surface, in: fixture) }
        // then
        #expect(goalContains("Couldn't save the goal. The run did not accept the new goal. Your draft is preserved.", surface, in: fixture))
        #expect(vm.goalDraft?.text == "Verify the release.")
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenRevisedGoalWithHistory_whenBlockRenders_thenLabelAndCollapsedHistoryShow(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: [
            "goal_revision": .number(3), "goal": .string("Verify the release and list pinned packages."),
            "goal_history": .array([
                .object(["revision": .number(1), "goal": .string("Verify.")]),
                .object(["revision": .number(2), "goal": .string("Verify the release.")])
            ])
        ])
        defer { vm.didDisappear(); fixture.close() }
        // when
        await fixture.settle { goalContains("Revision history", surface, in: fixture) }
        // then
        #expect(goalContains("Goal · revision 3", surface, in: fixture))
        #expect(goalContains("Verify the release and list pinned packages.", surface, in: fixture))
        #expect(!goalContains("Revision 2", surface, in: fixture), "The history is collapsed until opened")
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenRevisionUnavailable_whenBlockRenders_thenLinkIsDisabledWithTheEngineReason(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: [
            "can_revise_goal": .bool(false), "goal_revision_reason": .string("Waiting for workers to finish.")
        ])
        defer { vm.didDisappear(); fixture.close() }
        // when
        await fixture.settle { goalContains("Waiting for workers to finish.", surface, in: fixture) }
        // then
        let candidates = goalElements(surface, in: fixture).filter { fixture.matches($0, "Revise goal…") }
        let link = try #require(candidates.first { fixture.string($0, "accessibilityRole") == NSAccessibility.Role.button.rawValue },
                                "The Revise goal link is exposed as a button")
        let isEnabled = try #require(accessibilityEnabledBySelector(link) ?? accessibilityEnabledByKVC(link),
                                     "The link reports its enabled state")
        #expect(!isEnabled, "The unavailable link is disabled")
        #expect(vm.selectedRun?.canReviseGoal == false)
    }

    @Test(arguments: GoalSurface.allCases, [ColorScheme.light, .dark])
    func givenLostRevisionRace_whenCallerAnswersFirst_thenGoalCardShowsAnswerAndSavedDraft(surface: GoalSurface, appearance: ColorScheme) async throws {
        // given
        let (vm, fixture) = try goalFixture(surface: surface, appearance: appearance, run: ["goal_revision": .number(3)])
        defer { vm.didDisappear(); fixture.close() }
        let receipt = try #require(WorkflowInteractionReceipt(.object([
            "interaction_id": .string("goal-1"), "workflow_run_id": .string("preview-run"), "action": .string("revise_goal"),
            "answer": .string("Caller goal text"), "answered_by": .string("caller"), "answered_at": .number(1793059200)
        ])))
        // when
        vm.retainInteractionOutcome(receipt, draft: "My unsaved goal", rootID: "preview-run")
        vm.goalRaceExpectedRevision = 3
        var raw = try #require(vm.selectedRun?.raw)
        raw["goal_revision"] = .number(4)
        raw["goal"] = .string("Caller goal text")
        vm.selectedRun = WorkflowRunModel(raw: raw)
        WorkflowPreview.synchronizeRun(vm)
        await fixture.settle { goalContains("Your saved draft", surface, in: fixture) }
        // then
        #expect(goalContains("Already answered by the caller", surface, in: fixture))
        #expect(goalContains("Caller goal text", surface, in: fixture))
        #expect(goalContains("My unsaved goal", surface, in: fixture))
        var seen = Set<ObjectIdentifier>()
        let copies = fixture.elements(in: fixture.window.contentView ?? fixture.host).filter { element in
            guard seen.insert(ObjectIdentifier(element)).inserted else { return false }
            return ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0) == "Already answered by the caller"
            }
        }
        #expect(copies.count == 1, "The outcome shows once: the card, not the screen header")
    }
}
