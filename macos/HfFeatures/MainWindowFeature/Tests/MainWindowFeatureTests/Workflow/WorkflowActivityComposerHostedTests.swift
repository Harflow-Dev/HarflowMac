import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowActivityComposerHostedTests

@MainActor @Suite(.serialized)
struct WorkflowActivityComposerHostedTests {
    @Test(arguments: [false, true])
    func givenActivityTargetDraft_whenSwitchingNativeOrChildTarget_thenOldDraftCannotBeSentToNewTarget(_ child: Bool) async throws {
        // given
        let harness = WorkflowTests().makeVM()
        defer { harness.sut.didDisappear() }
        let first = run(child: child, suffix: "a")
        let next = run(child: child, suffix: "b")
        given(harness.useCase)
.command(.any, options: .any, positionals: .any, runtime: .any)
            .willProduce { command, _, positionals, _ in
                if command == "status" {
                    return positionals.first == String(repeating: "c", count: 32) ? next
                        : ["workflow_run_id": .string(positionals[0]), "status": .string("running")]
                }
                return ["status": .string("queued")]
            }
        select(first, in: harness.sut)
        let fixture = RedesignHost(WorkflowActivityMessageComposer(viewModel: harness.sut), size: CGSize(width: 420, height: 280))
        defer { fixture.close() }
        fixture.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        await fixture.settle { fixture.window.isKeyWindow && field(in: fixture) != nil }
        let original = try #require(field(in: fixture))
        #expect(fixture.window.makeFirstResponder(original))
        edit(original, text: "Only for target A")
        await fixture.settle { original.stringValue == "Only for target A" }

        // when
        select(next, in: harness.sut)
        await fixture.settle { field(in: fixture)?.stringValue.isEmpty == true }
        let current = try #require(field(in: fixture))
        #expect(fixture.window.makeFirstResponder(current))
        _ = fixture.window.performKeyEquivalent(with: try submitEvent(in: fixture))
        await Task.yield()

        // then
        #expect(current.stringValue.isEmpty)
        verify(harness.useCase).command(.value("send"), options: .any, positionals: .any, runtime: .any).called(0)
        edit(current, text: "Only for target B")
        // Native text editing updates SwiftUI state on the next presentation. Wait for
        // the actual action to enable before invoking its focus-scoped shortcut.
        await fixture.settle {
            guard let send = fixture.element("Send") as? any NSAccessibilityProtocol else { return false }
            return current.currentEditor() != nil && send.isAccessibilityEnabled()
        }
        #expect(fixture.window.performKeyEquivalent(with: try submitEvent(in: fixture)))
        let runID = child ? String(repeating: "b", count: 32) : String(repeating: "c", count: 32)
        let options = ["--monitor", "--delivery=queue"] + (child ? [] : ["--task-id=native-b"])
        await verify(harness.useCase)
.command(.value("send"), options: .value(options),
            positionals: .value([runID, "Only for target B"]), runtime: .any)
.calledEventually(1, before: .seconds(5))
        verify(harness.useCase)
.command(.value("send"), options: .any,
            positionals: .matching { $0.last == "Only for target A" }, runtime: .any)
.called(0)
    }

    private func select(_ raw: [String: JSONValue], in vm: WorkflowVM) {
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.selectedNodeID = "work"
        vm.runSidebar = WorkflowRunSidebarPresentation.build(run: raw, nodeID: "work", attemptID: nil)
    }

    private func run(child: Bool, suffix: String) -> [String: JSONValue] {
        var activation: [String: JSONValue] = ["id": .string("execution-" + suffix), "role": .string("node"),
            "node_id": .string("work"), "status": .string("running"), "tasks": .array([])]
        if child {
            activation["invocation"] = .object(["child_workflow_run_id": .string(String(repeating: suffix, count: 32))])
        } else {
            activation["execution_kind"] = .string("native_subagent")
            activation["tasks"] = .array([.object(["task_id": .string("native-" + suffix), "status": .string("running")])])
        }
        return ["workflow_run_id": .string(String(repeating: "c", count: 32)), "status": .string("running"),
            "definition": .object(["nodes": .array([.object(["id": .string("work"), "type": .string(child ? "workflow" : "agent")])])]),
            "activations": .array([.object(activation)])]
    }

    private func field(in fixture: RedesignHost) -> NSTextField? {
        fixture.descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Queue a message…" }
    }

    private func edit(_ field: NSTextField, text: String) {
        field.stringValue = text
        field.currentEditor()?.string = text
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func submitEvent(in fixture: RedesignHost) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r",
            isARepeat: false, keyCode: 36))
    }
}
