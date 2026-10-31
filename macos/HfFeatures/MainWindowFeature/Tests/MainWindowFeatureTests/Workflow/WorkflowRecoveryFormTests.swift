import AppKit
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - WorkflowRecoveryFormTests

@MainActor @Suite(.serialized) struct WorkflowRecoveryFormTests {
    @Test(arguments: [ColorScheme.light, .dark], [true, false])
    func givenRecoveryRefusalState_whenHostedForCapture_thenShowsProductionFormInLightAndDark(appearance: ColorScheme, checkpointAvailable: Bool) async throws {
        // given
        guard let path = ProcessInfo.processInfo.environment["HARFLOW_RECOVERY_CAPTURE_DIR"], !path.isEmpty else { return }
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        given(harness.useCase)
            .command(.value("status"), options: .value(["--monitor-view", "--snapshot"]),
                     positionals: .value(["recovery-form-run"]), runtime: .any)
            .willReturn(recoveryFormRun(status: "needs_attention", question: "A newer request.",
                                        checkpoint: "attention:recovery-form-run:checkpoint-2").raw)
        if checkpointAvailable {
            vm.selectedRun = recoveryFormRun(status: "needs_attention", question: "The workflow changed while you were reviewing it.")
            vm.instructions = "Preserve the work already completed."
            given(harness.useCase)
.command(.value("resume"), options: .any, positionals: .any, runtime: .any)
                .willThrow(ToolError.refused(code: "attention_checkpoint_stale", message: "stale"))
        } else {
            vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("recovery-form-run"), "status": .string("needs_attention"),
                                                    "input_question": .string("This older engine cannot identify the displayed checkpoint.")])
            vm.instructions = "Preserve the work already completed."
        }
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}),
                                   size: CGSize(width: 1440, height: 900), appearance: appearance)
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        if checkpointAvailable {
            let resume = try #require(fixture.element("Resume"))
            #expect(fixture.press(resume))
            await fixture.settle { !vm.isBusy && vm.errorText?.contains("checkpoint changed") == true }
        }

        // then
        await fixture.settle { fixture.hasRenderedInk }
        #expect(vm.instructions == "Preserve the work already completed.")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mode = appearance == .light ? "light" : "dark"
        let state = checkpointAvailable ? "stale" : "unsupported"
        try fixture.capturePNG(to: directory.appendingPathComponent("recovery-\(state)-\(mode).png"))
    }

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
        verify(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).called(0)
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
        verify(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).called(0)
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
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume))

        // then
        await verify(harness.useCase)
.command(.value("resume"), options: .value(["--monitor", "--instructions=Continue with the current approach.", "--additional-attempts=0",
                                             "--attention-checkpoint-id=attention:recovery-form-run:checkpoint-1"]),
    positionals: .value(["recovery-form-run"]), runtime: .any)
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
        vm.additionalAttempts = 42
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}), size: CGSize(width: 520, height: 360))
        defer { fixture.close() }
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        await fixture.settle { fixture.element("Recover") != nil }

        // when
        let recover = try #require(fixture.element("Recover"))
        #expect(fixture.press(recover))

        // then
        await verify(harness.useCase)
.command(.value("recover"), options: .value(["--monitor", "--reason=Recover the existing work.", "--additional-attempts=42",
                                             "--attention-checkpoint-id=attention:recovery-form-run:checkpoint-1"]),
    positionals: .value(["recovery-form-run"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
        await fixture.settle { !vm.isBusy }
    }

    @Test func givenLegacyRecoveryWithoutCheckpoint_whenHosted_thenControlIsUnavailable() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("recovery-form-run"), "status": .string("needs_attention"),
                                                "input_question": .string("The worker stopped.")])
        vm.instructions = "Keep my draft."
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}), size: CGSize(width: 520, height: 360))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when / then
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume) == false)
        #expect(vm.instructions == "Keep my draft.")
        verify(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).called(0)
    }

    @Test func givenCheckpointChangesDuringSubmission_whenHosted_thenDraftRemainsAndStaleRefusalIsShown() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = recoveryFormRun(status: "needs_attention", question: "Choose the next approach.")
        vm.instructions = "Preserve this exact draft."
        given(harness.useCase)
.command(.value("resume"), options: .any, positionals: .any, runtime: .any)
            .willThrow(ToolError.refused(code: "attention_checkpoint_stale", message: "stale"))
        given(harness.useCase)
            .command(.value("status"), options: .value(["--monitor-view", "--snapshot"]),
                     positionals: .value(["recovery-form-run"]), runtime: .any)
            .willReturn(recoveryFormRun(status: "needs_attention", question: "A newer request.",
                                        checkpoint: "attention:recovery-form-run:checkpoint-2").raw)
        let fixture = RedesignHost(WorkflowRecoveryForm(viewModel: vm, onClose: {}), size: CGSize(width: 520, height: 360))
        defer { fixture.close() }
        await fixture.settle { fixture.element("Resume") != nil }

        // when
        let resume = try #require(fixture.element("Resume"))
        #expect(fixture.press(resume))

        // then
        await fixture.settle { !vm.isBusy }
        #expect(vm.instructions == "Preserve this exact draft.")
        #expect(vm.errorText?.contains("checkpoint changed") == true)
        await verify(harness.useCase)
            .command(.value("resume"), options: .value(["--monitor", "--instructions=Preserve this exact draft.", "--additional-attempts=0",
                                                         "--attention-checkpoint-id=attention:recovery-form-run:checkpoint-1"]),
                positionals: .value(["recovery-form-run"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))

        vm.selectedRun = recoveryFormRun(
            status: "needs_attention", question: "A newer request.", checkpoint: "attention:recovery-form-run:checkpoint-2"
        )
        vm.control("resume")
        #expect(vm.instructions == "Preserve this exact draft.")
        #expect(vm.errorText == WorkflowContinuationDraftContext.changedMessage)
        await verify(harness.useCase)
            .command(.value("resume"), options: .any, positionals: .any, runtime: .any)
            .calledEventually(1, before: .seconds(5))
    }

    @Test func givenDraftBoundToOlderCheckpoint_whenSelectedCheckpointChanges_thenOnlyExplicitlyClearedDraftCanSubmit() async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let vm = harness.sut
        defer { vm.didDisappear() }
        vm.selectedRun = recoveryFormRun(
            status: "needs_attention", question: "First request.", checkpoint: "attention:recovery-form-run:checkpoint-1"
        )
        vm.instructions = "Answer for the first request."
        vm.additionalAttempts = 3

        // when
        vm.selectedRun = recoveryFormRun(
            status: "needs_attention", question: "Second request.", checkpoint: "attention:recovery-form-run:checkpoint-2"
        )
        vm.control("resume")

        // then
        #expect(vm.instructions == "Answer for the first request.")
        #expect(vm.additionalAttempts == 3)
        #expect(vm.errorText == WorkflowContinuationDraftContext.changedMessage)
        verify(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).called(0)

        // Clearing both fields releases the old authorization; the new answer binds to checkpoint 2.
        vm.instructions = ""
        vm.additionalAttempts = 0
        vm.instructions = "Answer for the second request."
        given(harness.useCase).command(.any, options: .any, positionals: .any, runtime: .any).willReturn([:])
        vm.control("resume")

        await verify(harness.useCase)
            .command(.value("resume"), options: .value(["--monitor", "--instructions=Answer for the second request.",
                                                         "--additional-attempts=0", "--attention-checkpoint-id=attention:recovery-form-run:checkpoint-2"]),
                positionals: .value(["recovery-form-run"]), runtime: .any)
            .calledEventually(1, before: .seconds(5))
        #expect(vm.instructions == "Answer for the second request.")
    }
}

private func recoveryFormRun(status: String, question: String, delegation: Bool = false,
                             checkpoint: String = "attention:recovery-form-run:checkpoint-1") -> WorkflowRunModel {
    var raw: [String: JSONValue] = [
        "workflow_run_id": .string("recovery-form-run"), "status": .string(status),
        "interaction_owner": .string("monitor"), "input_question": .string(question)
    ]
    if status == "needs_attention" || status == "failed" {
        raw["attention_checkpoint_id"] = .string(checkpoint)
    }
    if delegation { raw["execution_contract"] = .string("delegation") }
    return WorkflowRunModel(raw: raw)
}
