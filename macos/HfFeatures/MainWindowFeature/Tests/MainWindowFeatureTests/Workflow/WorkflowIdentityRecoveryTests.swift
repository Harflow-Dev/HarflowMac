import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowIdentityRecoveryTests

@MainActor @Suite struct WorkflowIdentityRecoveryTests {
    @Test(arguments: ["", "workflow:run", "bad id", ".run", "_run", "-run", String(repeating: "x", count: 101), "é"])
    func givenInvalidNavigationIdentity_whenRefreshing_thenNoCLIRequestAndLoadingSettles(_ id: String) async {
        // given
        let harness = WorkflowTests().makeVM()
        harness.sut.prepareRun(id: id, polling: WorkflowRunPolling())
        // when
        await harness.sut.refresh()
        // then
        #expect(harness.sut.initialLoadingKind == nil)
        #expect(harness.sut.initialLoadFailed)
        #expect(harness.sut.errorText?.contains("invalid run identifier") == true)
        // Mock command is deliberately unstubbed: any CLI request fails this test.
    }

    @Test(arguments: ["", "other"])
    func givenMalformedStatus_whenReopeningRequestedRun_thenCacheCannotReplaceIdentity(_ responseID: String) async throws {
        // given
        let harness = WorkflowTests().makeVM()
        let polling = WorkflowRunPolling()
        var response: [String: JSONValue] = ["status": .string("running")]
        if !responseID.isEmpty { response["workflow_run_id"] = .string(responseID) }
        given(harness.useCase).command(.any, options: .any, positionals: .any).willReturn(response)
        // when
        _ = try await polling.load(id: "run", useCase: harness.useCase)
        harness.sut.prepareRun(id: "run", polling: polling)
        // then
        #expect(polling.cached(id: "run") == nil)
        #expect(harness.sut.selectedRun?.id == "run")
        #expect(harness.sut.initialLoadingKind == "run")
    }

    @Test(arguments: ["run", "run_1", "run-1.2", String(repeating: "x", count: 100)])
    func givenValidRunIdentity_whenValidated_thenPreservesContract(_ id: String) {
        // given / when / then
        #expect(WorkflowRunIdentity.isValid(id))
    }
}
