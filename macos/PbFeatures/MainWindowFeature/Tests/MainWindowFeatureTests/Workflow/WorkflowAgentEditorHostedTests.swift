import AppKit
@testable import MainWindowFeature
import MonitorCore
import Observation
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowAgentEditorHostedTests

@MainActor @Suite(.serialized) struct WorkflowAgentEditorHostedTests {
    @Test(arguments: [220.0, 288.0], [ColorScheme.light, .dark])
    func givenNarrowCandidateEditor_whenEditingAndReordering_thenNativeControlsRemainContained(width: Double, appearance: ColorScheme) async throws {
        // given
        let state = HostedCandidateState()
        let fixture = RedesignHost(
            ScrollView {
                WorkflowAgentEditor(candidate: Binding(get: { state.candidate }, set: { state.candidate = $0 }),
                                    backendIDs: ["codex", "claude", "vibe"], modelChoices: [:],
                                    loadModels: { state.loadedBackends.append($0) })
                    .padding(PbRadius.Metrics.spacing16)
            }.preferredColorScheme(appearance), size: CGSize(width: width, height: 900)
        )
        defer { fixture.close() }
        await fixture.settle { fixture.element("Model") != nil }
        let field = try #require(fixture.descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Default" })

        // when: edit the actual native custom-model field, rather than the presentation mapper.
        field.stringValue = "custom-provider/model-with-an-unlisted-name"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await fixture.settle { state.candidate["model"]?.stringValue == field.stringValue }

        // then
        #expect(state.candidate["model"]?.stringValue == "custom-provider/model-with-an-unlisted-name")
        #expect(state.loadedBackends.contains("claude"))
        try assertControlsFit(fixture)

        // when: expand and operate the actual ordered-fallback controls.
        let disclosure = try #require(fixture.element("Fallback agents (2)"))
        #expect(fixture.press(disclosure))
        await fixture.settle { fixture.element("Move fallback 1 down") != nil }
        try assertControlsFit(fixture)
        let move = try #require(fixture.element("Move fallback 1 down"))
        #expect(fixture.press(move))
        await fixture.settle { WorkflowAgentEditorOperations.fallbacks(state.candidate).first?["backend"]?.stringValue == "vibe" }
        #expect(WorkflowAgentEditorOperations.fallbacks(state.candidate).map { $0["backend"]?.stringValue } == ["vibe", "codex"])
        let remove = try #require(fixture.element("Remove fallback 2"))
        #expect(fixture.press(remove))
        await fixture.settle { WorkflowAgentEditorOperations.fallbacks(state.candidate).count == 1 }
        let add = try #require(fixture.element("Add fallback"))
        #expect(fixture.press(add))
        await fixture.settle { WorkflowAgentEditorOperations.fallbacks(state.candidate).count == 2 }
        #expect(WorkflowAgentEditorOperations.fallbacks(state.candidate).map { $0["backend"]?.stringValue } == ["vibe", "codex"])

        // when / then: the real binding's backend change reloads models and preserves Vibe eligibility.
        state.candidate = WorkflowCandidateSettings.replacingBackend(in: state.candidate, with: "vibe")
        await fixture.settle { state.loadedBackends.contains("vibe") }
        #expect(state.loadedBackends.contains("vibe"))
        let allModels = fixture.descendants.compactMap { $0 as? NSTextField }.filter { $0.placeholderString == "Default" }
        #expect(allModels.count == 1, "Only the Codex fallback retains its model field; the Vibe primary and fallback omit theirs")
    }

    @Test(arguments: [true, false], [ColorScheme.light, .dark])
    func givenActualLaunchSheet_whenSharedEditorIsUsed_thenCustomModelsAndOriginalGuardsRemain(isGenerating: Bool, appearance: ColorScheme) async throws {
        // given: the existing sheet is actually 580 points; this test does not claim a narrower sheet.
        let vm = WorkflowPreview.make()
        vm.overrideOrchestrator = true
        vm.generationAgent = ["backend": .string("claude")]
        vm.launchAgent = ["backend": .string("claude")]
        vm.prompt = ""
        let fixture = RedesignHost(WorkflowLaunchSheet(viewModel: vm, isGenerating: isGenerating).preferredColorScheme(appearance),
                                   size: CGSize(width: 580, height: 650))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Model") != nil }
        let field = try #require(fixture.descendants.compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Default" })

        // when
        field.stringValue = "custom-sheet-model"
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        await fixture.settle {
            (isGenerating ? vm.generationAgent : vm.launchAgent)["model"]?.stringValue == "custom-sheet-model"
        }

        // then
        #expect((isGenerating ? vm.generationAgent : vm.launchAgent)["model"]?.stringValue == "custom-sheet-model")
        let submit = try #require(fixture.element(isGenerating ? "Generate" : "Run"))
        #expect(!enabled(submit), "The original empty-request submission guard stays in effect")
        if isGenerating {
            #expect(fixture.element("Fallback agents (0)") != nil)
        } else {
            #expect(fixture.element("Override orchestrator agent") != nil)
            #expect(fixture.element("Saved fallback agents remain in effect.") != nil)
            #expect(fixture.element("Fallback agents (0)") == nil)
        }
        let frame = field.convert(field.bounds, to: nil)
        #expect(frame.width > 0 && frame.minX >= 0 && frame.maxX <= 580)
    }

    private func enabled(_ element: NSObject) -> Bool {
        if let accessible = element as? any NSAccessibilityProtocol { return accessible.isAccessibilityEnabled() }
        return (element.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue ?? false
    }

    private func assertControlsFit(_ fixture: RedesignHost) throws {
        for field in fixture.descendants.compactMap({ $0 as? NSTextField }).filter(\.isEditable) {
            let frame = field.convert(field.bounds, to: nil)
            #expect(frame.width > 0 && frame.minX >= -1 && frame.maxX <= fixture.window.contentLayoutRect.maxX + 1,
                    "Editable field overflow at \(fixture.window.contentLayoutRect.width) points")
        }
        for label in ["Agent", "Model", "Suggested models", "Effort", "Turn limit"] {
            let control = try #require(fixture.element(label))
            let frame = try #require(fixture.frame(control))
            #expect(frame.width > 0 && frame.minX >= -1 && frame.maxX <= fixture.window.contentLayoutRect.maxX + 1,
                    "Shared editor control overflow: \(label)")
        }
    }
}

// MARK: - HostedCandidateState

@MainActor @Observable private final class HostedCandidateState {
    var candidate: [String: JSONValue] = [
        "backend": .string("claude"), "model": .string("opus"),
        "fallbacks": .array([.object(["backend": .string("codex")]), .object(["backend": .string("vibe")])])
    ]
    var loadedBackends: [String] = []
}
