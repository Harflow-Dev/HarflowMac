import AppKit
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import SwiftUI
import Testing

// MARK: - WorkflowRecoveryFormTests

@MainActor @Suite(.serialized) struct WorkflowRecoveryFormTests {
    @Test func givenRecoveryForm_whenClosed_thenRetainsInputAndAttemptsWithoutCommand() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = run(status: "needs_attention", question: "Choose the next approach.")
        vm.instructions = "Keep the existing implementation."
        vm.additionalAttempts = 7
        var didClose = false
        let fixture = RedesignHost(
            WorkflowRecoveryForm(viewModel: vm, onClose: { didClose = true }),
            size: CGSize(width: 520, height: 360)
        )
        defer { fixture.close() }
        await fixture.settle { fixture.element("Close recovery options") != nil }

        // when
        let close = try #require(fixture.element("Close recovery options"))
        #expect(fixture.press(close))

        // then
        #expect(didClose)
        #expect(vm.instructions == "Keep the existing implementation.")
        #expect(vm.additionalAttempts == 7)
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }

    @Test func givenBlankRequiredAnswer_whenHosted_thenResumeRemainsDisabled() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = run(status: "needs_input", question: "Which option should continue?", delegation: true)
        vm.instructions = " \n "
        let fixture = RedesignHost(
            WorkflowRecoveryForm(viewModel: vm, onClose: {}),
            size: CGSize(width: 520, height: 360)
        )
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when / then
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume) == false)
        verify(harness.useCase).command(.any, options: .any, positionals: .any).called(0)
    }

    @Test func givenFailedRecoveryWithAnswer_whenHosted_thenShowsRecoverAndBoundedNativeStepper() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = run(status: "failed", question: "The worker stopped.", delegation: true)
        vm.instructions = "Recover the existing work."
        vm.additionalAttempts = 42
        let fixture = RedesignHost(
            WorkflowRecoveryForm(viewModel: vm, onClose: {}),
            size: CGSize(width: 520, height: 360)
        )
        defer { fixture.close() }
        await fixture.settle {
            fixture.element("Recover") != nil
                && uniqueElements(in: fixture).contains { fixture.string($0, "accessibilityRole") == "AXIncrementor" }
        }

        // when
        let stepper = try #require(uniqueElements(in: fixture).first {
            fixture.string($0, "accessibilityRole") == "AXIncrementor"
        })
        #expect(fixture.element("Extra attempts: 42") != nil)
        #expect(value(stepper) == 42)
        perform(stepper, selector: "accessibilityPerformIncrement")

        // then
        #expect(fixture.element("Recover") != nil)
        #expect(vm.additionalAttempts == 43)
        #expect(fixture.element("Extra attempts: 43") != nil)
        #expect(value(stepper) == 43)

        // Logical limits remain the view-model contract even though SwiftUI renders a relative
        // native NSStepper proxy around the current value.
        vm.additionalAttempts = 0
        await fixture.settle { fixture.element("Extra attempts: 0") != nil }
        perform(stepper, selector: "accessibilityPerformDecrement")
        await fixture.settle { vm.additionalAttempts == 0 }
        vm.additionalAttempts = 100
        await fixture.settle { fixture.element("Extra attempts: 100") != nil }
        perform(stepper, selector: "accessibilityPerformIncrement")
        await fixture.settle { vm.additionalAttempts == 100 }
        #expect(vm.additionalAttempts <= 100)
    }

    private func uniqueElements(in fixture: RedesignHost) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        return fixture.descendants.flatMap { fixture.elements(in: $0) }.filter {
            seen.insert(ObjectIdentifier($0)).inserted
        }
    }

    private func value(_ object: NSObject) -> Int? {
        let selector = NSSelectorFromString("accessibilityValue")
        guard object.responds(to: selector) else { return nil }
        return (object.perform(selector)?.takeUnretainedValue() as? NSNumber)?.intValue
    }

    private func perform(_ object: NSObject, selector name: String) {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector), let accessible = object as? any NSAccessibilityProtocol else { return }
        if name == "accessibilityPerformIncrement" {
            _ = accessible.accessibilityPerformIncrement()
        } else {
            _ = accessible.accessibilityPerformDecrement()
        }
    }

}

private func run(status: String, question: String, delegation: Bool = false) -> WorkflowRunModel {
    recoveryFormRun(status: status, question: question, delegation: delegation)
}

@MainActor @Suite(.serialized) struct WorkflowRecoveryResumeDispatchTests {

    // MARK: - Resume dispatch

    @Test func givenAnsweredAttentionRun_whenResumeIsPressed_thenDispatchesExistingResumeControl() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = recoveryFormRun(status: "needs_attention", question: "Choose the next approach.")
        vm.instructions = "Continue with the current approach."
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}), size: CGSize(width: 520, height: 360))
        defer { fixture.close() }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume))

        // then
        await verify(harness.useCase)
.command(.value("resume"), options: .any, positionals: .value(["recovery-form-run"]))
            .calledEventually(1, before: .seconds(5))
        await fixture.settle { !vm.isBusy }
    }
}

@MainActor @Suite(.serialized) struct WorkflowRecoveryRecoverDispatchTests {

    // MARK: - Recover dispatch

    @Test func givenFailedRunWithAnswer_whenRecoverIsPressed_thenDispatchesExistingRecoverControl() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = recoveryFormRun(status: "failed", question: "The worker stopped.", delegation: true)
        vm.instructions = "Recover the existing work."
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}), size: CGSize(width: 520, height: 360))
        defer { fixture.close() }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        await fixture.settle { fixture.element("Recover") != nil }

        // when
        let recover = try #require(fixture.element("Recover"))
        #expect(fixture.press(recover))

        // then
        await verify(harness.useCase)
.command(.value("recover"), options: .any, positionals: .value(["recovery-form-run"]))
            .calledEventually(1, before: .seconds(5))
        await fixture.settle { !vm.isBusy }
    }
}

private func recoveryFormRun(status: String, question: String, delegation: Bool = false) -> WorkflowRunModel {
    var raw: [String: JSONValue] = [
        "workflow_run_id": .string("recovery-form-run"), "status": .string(status),
        "interaction_owner": .string("monitor"), "input_question": .string(question)
    ]
    if delegation { raw["execution_contract"] = .string("delegation") }
    return WorkflowRunModel(raw: raw)
}
