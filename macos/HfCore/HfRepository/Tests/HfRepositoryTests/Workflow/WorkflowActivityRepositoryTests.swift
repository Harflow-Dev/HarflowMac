import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

// MARK: - WorkflowActivityRepositoryTests

struct WorkflowActivityRepositoryTests {
    @Test func givenRuntimeChangedAfterResponse_whenReadingActivity_thenRepositoryDiscardsAnswer() async throws {
        // given
        let selected = LockedBox("/fixture/first/ctl")
        let runner = compatibleRunner { _ in
            selected.mutate { $0 = "/fixture/second/ctl" }
            return .success(stdout(#"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"0.0.1","#
                + #""result":{"workflow_run_id":"run","execution_id":"exec","events":[],"has_more":false}}"#))
        }
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce {
            .success(CtlClient(executable: selected.value, environment: [:], runner: runner))
        }
        let repository = WorkflowRepositoryImpl(toolEnvironment: tooling)
        let runtime = try repository.activityRuntime()
        // when
        let result = try? await repository.activity(runID: "run", executionID: "exec", intent: .settledOnly, runtime: runtime)
        // then
        #expect(result == nil)
        #expect(runner.calls.filter { $0.arguments.first == "workflow-inspect" }.count == 1)
    }

    @Test func givenRuntimeChangedBeforeRead_whenUsingCapturedToken_thenNoOperationLaunches() async throws {
        // given
        let selected = LockedBox("/fixture/first/ctl")
        let runner = compatibleRunner { _ in .success(stdout("{}")) }
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willProduce {
            .success(CtlClient(executable: selected.value, environment: [:], runner: runner))
        }
        let repository = WorkflowRepositoryImpl(toolEnvironment: tooling)
        let runtime = try repository.activityRuntime()
        selected.mutate { $0 = "/fixture/second/ctl" }
        // when
        let result = try? await repository.activity(runID: "run", executionID: "exec", intent: .settledOnly, runtime: runtime)
        // then
        #expect(result == nil)
        #expect(runner.calls.isEmpty)
    }
}
