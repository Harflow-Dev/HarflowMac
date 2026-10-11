import AppKit
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowRunSidebarHostedTests

@MainActor @Suite(.serialized) struct WorkflowRunSidebarHostedTests {
    @Test(arguments: [220.0, 288.0], [ColorScheme.light, .dark])
    func givenPopulatedChildRun_whenSidePanelScrolls_thenDisclosuresHistoryAndRoutesRemainReachable(width: Double, appearance: ColorScheme) async throws {
        // given
        let (vm, routing, raw, nodeID) = try makeRun()
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: CGSize(width: 900, height: 700))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Open owning orchestrator") != nil }
        vm.didDisappear()
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = nodeID
        let split = try #require(fixture.descendants.compactMap { $0 as? NSSplitView }.first { $0.isVertical })
        split.setPosition(split.bounds.width - width - split.dividerThickness, ofDividerAt: 0)
        await fixture.settle { abs((split.arrangedSubviews.last?.bounds.width ?? 0) - width) < 1 }
        let pane = try #require(split.arrangedSubviews.last)
        let scroll = try #require(allViews(pane).compactMap { $0 as? NSScrollView }.first)

        // when / then: the real retained side panel, not a checklist-only facsimile.
        #expect(abs(pane.bounds.width - width) < 1)
        #expect(fixture.element("Child workflow · Plan and checklist belong to this run") != nil)
        let owner = try await reveal("Open owning orchestrator", using: scroll, fixture: fixture)
        #expect(fixture.press(owner))
        verify(routing).openWorkflowRun(id: .value("preview-owner-run")).called(1)
        let child = try await reveal("Select child workflow Review, run 1, completed", using: scroll, fixture: fixture)
        #expect(fixture.press(child))
        verify(routing).openWorkflowRun(id: .value("preview-child-run")).called(1)
        try await openDisclosures(using: scroll, fixture: fixture)
        #expect(fixture.element("Assignment for this child") != nil)
        #expect(fixture.element("Technical plan") != nil)
        let activity = try await reveal("Show activity", using: scroll, fixture: fixture)
        #expect(fixture.press(activity))
        await fixture.settle { vm.selectedActivationID == "older-attempt" }
        #expect(vm.selectedActivationID == "older-attempt", "A selected older activation must not silently jump to the latest")
        let latest = try await reveal("Show latest steps", using: scroll, fixture: fixture)
        #expect(fixture.press(latest))
        await fixture.settle { vm.selectedActivationID == nil }
        #expect(vm.selectedActivationID == nil)

        // when / then: root runs retain the same request, with their original disclosure label.
        try await checkRootRequest(vm: vm, raw: raw, scroll: scroll, fixture: fixture)
    }

    private func reveal(_ label: String, using scroll: NSScrollView, fixture: RedesignHost) async throws -> NSObject {
        let document = try #require(scroll.documentView)
        var previousFrame = CGRect.zero
        await fixture.settle {
            guard let element = scopedElement(label, document: document, fixture: fixture),
                  let frame = fixture.frame(element) else { return false }
            document.scrollToVisible(document.convert(frame, from: nil))
            scroll.reflectScrolledClipView(scroll.contentView)
            let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
            let stable = frame == previousFrame
            previousFrame = frame
            return stable && visible.insetBy(dx: -1, dy: -1).contains(frame)
        }
        let element = try #require(scopedElement(label, document: document, fixture: fixture))
        let visible = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let reached = try #require(fixture.frame(element))
        #expect(reached.width > 0 && reached.height > 0)
        #expect(visible.insetBy(dx: -1, dy: -1).contains(reached),
                "Side-panel \(label) [\(fixture.string(element, "accessibilityRole") ?? "unknown")] must remain inside \(visible); actual \(reached)")
        return element
    }

    private func makeRun() throws -> (WorkflowVM, MockWorkflowRouting, [String: JSONValue], String) {
        let preview = WorkflowPreview.makePopulatedChildRun()
        defer { preview.didDisappear() }
        var raw = try #require(preview.selectedRun?.raw)
        let nodeID = try #require(preview.selectedNodeID)
        raw["activations"] = .array([
            .object(["id": .string("older-attempt"), "role": .string("node"), "node_id": .string(nodeID),
                     "status": .string("completed"), "attempt_in_visit": .number(1),
                     "assignment_prompt": .string("Retained assignment from the earlier activation."),
                     "invocation": .object(["child_workflow_run_id": .string("preview-child-run"),
                                             "workflow_name": .string("Review"), "stage": .string("completed")])]),
            .object(["id": .string("newer-attempt"), "role": .string("node"), "node_id": .string(nodeID),
                     "status": .string("completed"), "attempt_in_visit": .number(2)])
        ])
        let routing = MockWorkflowRouting()
        given(routing).openWorkflowRun(id: .any).willReturn()
        let useCase = MockWorkflowUseCase()
        given(useCase).backendIDs.willReturn(["codex", "claude"])
        given(useCase).modelOptions(backend: .any).willReturn([])
        given(useCase).refreshTasks().willReturn()
        given(useCase).command(.any, options: .any, positionals: .any).willReturn(raw)
        let vm = WorkflowVM(useCase: useCase, routing: routing, parallel: ParallelVMTests().makeSUT().sut,
                            draftStore: WorkflowDraftStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        vm.definition = preview.definition
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = nodeID
        return (vm, routing, raw, nodeID)
    }

    private func openDisclosures(using scroll: NSScrollView, fixture: RedesignHost) async throws {
        for label in ["Assignment for this child", "Technical plan"] {
            let disclosure = try await reveal(label, using: scroll, fixture: fixture)
            #expect(fixture.press(disclosure))
            let sourceText = label == "Technical plan"
                ? "Bump the version constant."
                : "Prepare the release: update the version, run the suite, and draft the changelog."
            await fixture.settle { containsText(sourceText, in: fixture) }
            #expect(containsText(sourceText, in: fixture), "The disclosure must expose its actual retained source text")
        }
    }

    private func checkRootRequest(vm: WorkflowVM, raw: [String: JSONValue], scroll: NSScrollView, fixture: RedesignHost) async throws {
        var root = raw
        root["parent_workflow_run_id"] = nil
        vm.selectedRun = WorkflowRunModel(raw: root)
        await fixture.settle { fixture.element("Original request") != nil }
        #expect(fixture.element("Assignment for this child") == nil)
        let request = try await reveal("Original request", using: scroll, fixture: fixture)
        // Disclosure state survives the child's label changing to its root label.
        if !containsText("Prepare the release:", in: fixture) { #expect(fixture.press(request)) }
        await fixture.settle { containsText("Prepare the release:", in: fixture) }
        #expect(containsText("Prepare the release:", in: fixture))
    }

    private func scopedElement(_ label: String, document: NSView, fixture: RedesignHost) -> NSObject? {
        allViews(document).flatMap { fixture.elements(in: $0) }.first { fixture.matches($0, label) }
    }

    private func allViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(allViews) }

    private func containsText(_ text: String, in fixture: RedesignHost) -> Bool {
        fixture.descendants.flatMap { fixture.elements(in: $0) }.contains { element in
            ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains {
                fixture.string(element, $0)?.contains(text) == true
            }
        }
    }
}
