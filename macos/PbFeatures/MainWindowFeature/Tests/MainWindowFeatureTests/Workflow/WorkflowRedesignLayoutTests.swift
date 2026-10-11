import AppKit
@testable import MainWindowFeature
import MonitorCore
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

// MARK: - WorkflowRedesignLayoutTests

/// Native hosted layout checks, complementary to the redesign's screenshot acceptance.
@MainActor @Suite(.serialized) struct WorkflowRedesignLayoutTests {
    @Test(arguments: ["", "Keep the existing changes."], [ColorScheme.light, .dark])
    func givenCompactRecovery_whenLaidOutAtRest_thenResumeAndInstructionsFitInsideExistingCap(answer: String, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        let question = "Scheduling is paused."
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("compact-recovery"),
                                               "status": .string("needs_attention"), "interaction_owner": .string("monitor"),
                                               "attention_reason": .string(question), "input_question": .string(question)])
        vm.instructions = answer
        let fixture = RedesignHost(
            RecoveryOverlayTestHarness(viewModel: vm)
                .preferredColorScheme(appearance), size: CGSize(width: 900, height: 700)
        )
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil && fixture.recoveryTextView != nil }

        // when: inspect the initial viewport without issuing any scroll action.
        let editor = try #require(fixture.recoveryTextView)
        let editorScroll = try #require(editor.enclosingScrollView)
        let outer = fixture.descendants.compactMap { $0 as? NSScrollView }.first { $0 !== editorScroll }
        let viewport = outer.map { $0.contentView.convert($0.contentView.bounds, to: nil) }
            ?? fixture.host.convert(fixture.host.bounds, to: nil)

        // then
        if let outer { #expect(abs(outer.contentView.bounds.origin.y) < 1) }
        for label in ["Extra attempts: 0", "Resume"] {
            let control = try #require(fixture.element(label))
            let frame = try #require(fixture.frame(control))
            #expect(viewport.insetBy(dx: -1, dy: -1).contains(frame), "Compact recovery action must be visible at rest: \(label)")
        }
        #expect(viewport.insetBy(dx: -1, dy: -1).contains(editorScroll.convert(editorScroll.bounds, to: nil)))
        #expect(editor.string == answer)
    }

    @Test(arguments: [ColorScheme.light, .dark])
    func givenNativeRecoveryEditor_whenAnswerGrowsAndClears_thenHeightGrowsWithinExistingLimits(appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make(run: true)
        vm.instructions = ""
        let fixture = RedesignHost(
            VStack {
                WorkflowRecoveryEditor(text: Binding(get: { vm.instructions }, set: { vm.instructions = $0 }))
                Spacer()
            }.preferredColorScheme(appearance), size: CGSize(width: 400, height: 300)
        )
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.descendants.contains { ($0 as? NSTextView)?.isEditable == true } }
        await fixture.settle {
            abs((fixture.recoveryTextView?.enclosingScrollView?.bounds.height ?? 0)
                - PbRadius.Metrics.recoveryEditorMinimumHeight) < 1
        }
        let emptyHeight = try #require(fixture.recoveryTextView?.enclosingScrollView?.bounds.height)
        #expect(abs(emptyHeight - PbRadius.Metrics.recoveryEditorMinimumHeight) < 1)

        // when
        vm.instructions = "First instruction.\nSecond instruction.\nThird instruction.\nFourth instruction."
        await fixture.settle {
            (fixture.recoveryTextView?.enclosingScrollView?.bounds.height ?? 0) > emptyHeight + 1
        }
        let wrappedHeight = try #require(fixture.recoveryTextView?.enclosingScrollView?.bounds.height)
        #expect(fixture.recoveryTextView?.string == vm.instructions)
        vm.instructions = String(repeating: "Preserve the existing public interface and inspect the resulting behavior.\n", count: 20)
        await fixture.settle {
            abs((fixture.recoveryTextView?.enclosingScrollView?.bounds.height ?? 0)
                - PbRadius.Metrics.recoveryEditorMaximumHeight) < 1
        }

        // then
        #expect(wrappedHeight > emptyHeight)
        #expect(wrappedHeight <= PbRadius.Metrics.recoveryEditorMaximumHeight)
        let editor = try #require(fixture.recoveryTextView)
        let scroll = try #require(editor.enclosingScrollView)
        #expect(abs(scroll.bounds.height - PbRadius.Metrics.recoveryEditorMaximumHeight) < 1)
        #expect(editor.string == vm.instructions)
        #expect(editor.bounds.height > scroll.contentView.bounds.height)

        // when / then: shrinking the same bound editor releases the added height.
        vm.instructions = ""
        await fixture.settle {
            abs((fixture.recoveryTextView?.enclosingScrollView?.bounds.height ?? 0) - emptyHeight) < 1
                && fixture.recoveryTextView?.string.isEmpty == true
        }
        #expect(abs((fixture.recoveryTextView?.enclosingScrollView?.bounds.height ?? 0) - emptyHeight) < 1)
        #expect(fixture.recoveryTextView?.string.isEmpty == true)
    }

    @Test(arguments: [700.0, 1200.0], [ColorScheme.light, .dark])
    func givenEditor_whenTrayWraps_thenEveryDragRoleStaysOutsideCanvas(width: Double, appearance: ColorScheme) async throws {
        // given
        let vm = WorkflowPreview.make()
        vm.connectionSourceID = "start"
        let fixture = RedesignHost(WorkflowView(vm).preferredColorScheme(appearance), size: CGSize(width: width, height: 700))
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Workflow steps") != nil && fixture.canvasScroll != nil }
        vm.didDisappear()
        vm.connectionSourceID = "start"
        await fixture.settle { fixture.element("Cancel connection") != nil }

        // when
        let scroll = try #require(fixture.canvasScroll)
        let viewport = scroll.contentView.convert(scroll.contentView.bounds, to: nil)
        let tray = try #require(fixture.element("Workflow steps"))
        let trayFrame = try #require(fixture.frame(tray))
        let chips = try WorkflowRole.palette.map { role in
            let title = WorkflowRole.title(role)
            return try #require(fixture.elements(in: tray).first { fixture.matches($0, title) })
        }
        let frames = try chips.map { try #require(fixture.frame($0)) }

        // then
        #expect(chips.count == 8)
        let nativeScrollInsets = scroll.bounds.width - scroll.contentView.bounds.width
        let minimumViewport = WorkflowInspectorWidth.canvasMinimumWidth - nativeScrollInsets
        #expect(viewport.width >= minimumViewport,
                "The canvas retains its 400-point pane minus its tokenized padding and measured native scroll border")
        #expect(trayFrame.maxY <= viewport.minY + 1, "Wrapped chrome must reserve real height below the native scroll region")
        for (chip, frame) in zip(chips, frames) {
            #expect(frame.width > 0 && frame.height > 0)
            #expect(trayFrame.insetBy(dx: -1, dy: -1).contains(frame))
            #expect(!viewport.intersects(frame))
            #expect(fixture.string(chip, "accessibilityRole") != NSAccessibility.Role.button.rawValue,
                    "A drag-only role must not acquire an insertion button")
        }
        if width == 700 {
            #expect((frames.map(\.midY).max() ?? 0) - (frames.map(\.midY).min() ?? 0) > 20,
                    "All eight roles must wrap at the minimum canvas width")
        }
        for label in ["Zoom out", "Reset zoom, currently 100 percent", "Zoom in"] {
            let control = try #require(fixture.element(label))
            let frame = try #require(fixture.frame(control))
            #expect(viewport.insetBy(dx: -1, dy: -1).contains(frame))
            #expect(!trayFrame.intersects(frame))
        }
        #expect(fixture.element("Workflow is valid") == nil)
        let cancel = try #require(fixture.element("Cancel connection"))
        #expect(fixture.press(cancel))
        await waitUntil { vm.connectionSourceID == nil }
    }

    @Test(arguments: [CGSize(width: 400, height: 300), CGSize(width: 900, height: 700)], [ColorScheme.light, .dark])
    func givenLongRecovery_whenViewportIsCapped_thenEveryExistingControlCanBeReached(size: CGSize, appearance: ColorScheme) async throws {
        // given: only test-local input fields already defined by the real run contract.
        let vm = WorkflowPreview.make(run: true)
        var raw = try #require(vm.selectedRun?.raw)
        raw["status"] = .string("needs_input")
        raw["execution_contract"] = .string("delegation")
        raw["interaction_owner"] = .string("monitor")
        raw["input_decision_id"] = .string("review-consent")
        raw["optional_review_skip_available"] = .bool(true)
        raw["exhausted_retry_edges"] = .array([.object(["edge_id": .string("retry")])])
        raw["input_question"] = .string(String(repeating: "Choose whether to restore the original public interface before continuing. ", count: 16))
        vm.selectedRun = WorkflowRunModel(raw: raw)
        vm.instructions = String(repeating: "Restore the original interface.\nKeep existing callers compatible.\n", count: 12)
        vm.additionalAttempts = 3
        let fixture = RedesignHost(
            RecoveryOverlayTestHarness(viewModel: vm).preferredColorScheme(appearance), size: size
        )
        defer { vm.didDisappear(); fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        let editor = try #require(fixture.descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable })
        let panel = try #require(fixture.descendants.compactMap { $0 as? WorkflowRecoveryPanelRootView }.first)
        let outer = try #require(fixture.descendants.compactMap { $0 as? NSScrollView }.first {
            $0 !== editor.enclosingScrollView && $0.isDescendant(of: panel)
        })
        let document = try #require(outer.documentView)
        let viewport = outer.contentView.convert(outer.contentView.bounds, to: nil)

        // then
        let panelMaximumHeight = size.height - 2 * PbRadius.Metrics.recoveryPanelInset
        #expect(outer.bounds.height <= panelMaximumHeight + 1)
        #expect(editor.string == vm.instructions, "Long multiline answers retain their complete content")
        let editorScroll = try #require(editor.enclosingScrollView)
        #expect(editorScroll.bounds.height >= PbRadius.Metrics.recoveryEditorMinimumHeight - 1)
        #expect(editorScroll.bounds.height <= PbRadius.Metrics.recoveryEditorMaximumHeight + 1)
        #expect(editor.bounds.height > editorScroll.contentView.bounds.height, "A long answer remains internally scrollable")
        for label in ["Extra attempts: 3", "Continue with one more retry", "Proceed without optional reviewer", "Resume"] {
            let control = try #require(fixture.element(label), "Missing real recovery control: \(label)")
            let frame = try #require(fixture.frame(control))
            #expect(frame.width > 0 && frame.height > 0)
            #expect(frame.minX >= viewport.minX - 1 && frame.maxX <= viewport.maxX + 1,
                    "Narrow recovery controls must wrap without horizontal clipping")
            let contentFrame = document.convert(frame, from: nil)
            document.scrollToVisible(contentFrame)
            outer.reflectScrolledClipView(outer.contentView)
            fixture.host.layoutSubtreeIfNeeded()
            let visible = outer.contentView.convert(outer.contentView.bounds, to: nil)
            let reached = try #require(fixture.frame(control))
            #expect(visible.insetBy(dx: -1, dy: -1).contains(reached), "Recovery control must be reachable by native scrolling: \(label)")
        }
        #expect(fixture.element("Waiting for the first step") == nil)
    }
}

private struct RecoveryOverlayTestHarness<VM: WorkflowViewModel>: View {
    let viewModel: VM
    @State private var presentation = WorkflowRecoveryOverlayPresentation()

    var body: some View {
        WorkflowRecoveryOverlayHost(viewModel: viewModel, presentation: $presentation, onExplicitClose: {})
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - RedesignHost

@MainActor final class RedesignHost {
    let host: NSHostingView<AnyView>
    let window: NSWindow
    private let previousEnhancedInterface: Any?

    init(_ view: some View, size: CGSize) {
        _ = NSApplication.shared
        self.previousEnhancedInterface = NSApplication.shared.accessibilityAttributeValue(
            NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        )
        NSApplication.shared.accessibilitySetValue(true, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        self.host = NSHostingView(rootView: AnyView(view.withPresentationContext()))
        self.window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
    }

    var descendants: [NSView] { views(host) }
    var recoveryTextView: NSTextView? { descendants.compactMap { $0 as? NSTextView }.first { $0.isEditable } }
    var canvasScroll: NSScrollView? { descendants.compactMap { $0 as? WorkflowCanvasScrollProbe }.first?.enclosingScrollView }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    func settle(_ predicate: () -> Bool) async {
        await waitUntil {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
            self.host.layoutSubtreeIfNeeded()
            self.host.displayIfNeeded()
            return predicate()
        }
    }

    func elements(in object: NSObject) -> [NSObject] {
        let selector = NSSelectorFromString("accessibilityChildren")
        guard object.responds(to: selector), let children = object.perform(selector)?.takeUnretainedValue() as? [NSObject] else { return [object] }
        return [object] + children.flatMap { elements(in: $0) }
    }

    func string(_ object: NSObject, _ property: String) -> String? {
        let selector = NSSelectorFromString(property)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue() as? String
    }

    func matches(_ object: NSObject, _ label: String) -> Bool {
        ["accessibilityLabel", "accessibilityTitle", "accessibilityValue"].contains { string(object, $0) == label }
    }

    func element(_ label: String) -> NSObject? {
        descendants.flatMap { elements(in: $0) }.first { matches($0, label) }
    }

    func frame(_ object: NSObject) -> CGRect? {
        if let accessible = object as? any NSAccessibilityProtocol { return window.convertFromScreen(accessible.accessibilityFrame()) }
        guard object.responds(to: NSSelectorFromString("accessibilityFrame")),
              let value = object.value(forKey: "accessibilityFrame") as? NSValue
        else { return nil }
        return window.convertFromScreen(value.rectValue)
    }

    func press(_ object: NSObject) -> Bool {
        if let accessible = object as? any NSAccessibilityProtocol { return accessible.accessibilityPerformPress() }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        let implementation = unsafeBitCast(object.method(for: selector), to: Press.self)
        return implementation(object, selector)
    }

    func close() {
        window.contentView = nil
        window.close()
        NSApplication.shared.accessibilitySetValue(previousEnhancedInterface,
                                                  forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
    }
}
