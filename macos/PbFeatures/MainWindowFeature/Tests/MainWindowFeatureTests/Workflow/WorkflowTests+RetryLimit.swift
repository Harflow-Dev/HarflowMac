import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbTestUtilities
import Testing

// MARK: - WorkflowTests retry limits

extension WorkflowTests {
    @Test func givenCanonicalRetryMetadata_whenLimitsAndTopologyChange_thenDraftStaysRawAndInferenceNeverStales() async throws {
        // given
        let useCase = MockWorkflowUseCase()
        let vm = WorkflowVM(useCase: useCase, routing: MockWorkflowRouting(), parallel: ParallelVMTests().makeSUT().sut)
        var raw = try fixture("definition")
        var connections = WorkflowJSON.objects(raw["connections"])
        let index = try #require(connections.firstIndex { $0["id"]?.stringValue == "review-fix" })
        connections[index]["backward"] = .bool(false)
        raw["connections"] = .array(connections.map(JSONValue.object))
        var canonical = raw
        connections[index]["backward"] = .bool(true)
        canonical["connections"] = .array(connections.map(JSONValue.object))
        given(useCase).validate(definition: .any).willReturn(["valid": .bool(true), "definition": .object(canonical)])
        vm.definition = raw
        vm.name = "retry"
        vm.selectedEdgeID = "review-fix"
        await waitUntil { vm.canonicalValidationDefinition != nil }
        // when
        #expect(vm.selectedEdge?.isBackward == true)
        #expect(vm.definition == raw)
        vm.updateEdge("review-fix", key: "max_retries", value: .number(3))
        // then — a limit edit keeps valid topology metadata and raw configuration.
        #expect(vm.selectedEdge?.isBackward == true)
        #expect(vm.selectedEdge?.maxRetries == 3)
        vm.updateEdge("review-fix", key: "target", value: .string("end"))
        #expect(vm.selectedEdge?.isBackward == false)
        #expect(vm.selectedEdge?.maxRetries == 3)
        #expect(vm.canonicalValidationDefinition == nil)
        vm.didDisappear()
    }

    @Test func givenRetryLimit_whenSetToZeroOrRemoved_thenZeroIsPreservedAndAbsenceRestoresUncappedMode() throws {
        // given
        let vm = makeVM().sut
        vm.definition = try fixture("definition")
        vm.selectedEdgeID = "review-fix"
        // when
        vm.updateEdge("review-fix", key: "max_retries", value: .number(0))
        // then
        #expect(vm.selectedEdge?.maxRetries == 0)
        vm.updateEdge("review-fix", key: "max_retries", value: nil)
        #expect(vm.selectedEdge?.maxRetries == nil)
    }

    @Test func givenExhaustedRetry_whenHumanContinues_thenExactlyOneAdditionalAttemptAndInstructionsAreSubmitted() async {
        // given
        let harness = makeVM()
        let vm = harness.sut
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn([:])
        vm.selectedRun = WorkflowRunModel(raw: ["workflow_run_id": .string("run"),
                                               "exhausted_retry_edges": .array([.string("retry")])])
        vm.instructions = "Try the alternate fix"
        vm.additionalAttempts = 9
        // when
        vm.continueWithOneMoreRetry()
        // then
        await verify(harness.useCase)
.command(.value("resume"),
                                             options: .value(["--instructions=Try the alternate fix", "--additional-attempts=1"]),
                                             positionals: .value(["run"]))
            .calledEventually(1, before: .seconds(5))
        #expect(vm.additionalAttempts == 1)
    }
}
