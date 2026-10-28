import Foundation
@testable import HfRepository
import Mockable
import MonitorCore
import Testing

struct QualificationBoundCommandTests {
    @Test func givenRuntimeChangesDuringHandshake_whenBoundClientCalls_thenNoLaunchCommandRuns() async throws {
        // given
        let current = LockedBox<CtlClient?>(nil)
        let compatible = compatibleRunner { _ in .success(stdout("{}")) }
        let runner = StubProcessRunner { call in
            let response = compatible.answer(call)
            if call.arguments == ["version-info", "--json"] {
                current.mutate { $0 = CtlClient(executable: "/fixture/replacement/ctl", environment: [:]) }
            }
            return response
        }
        let client = CtlClient(executable: "/fixture/original/ctl", environment: [:], runner: runner)
        current.mutate { $0 = client }
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willProduce { .success(current.value!) }
        let bound = try QualificationRuntimeToken(client: client).boundClient(tooling: environment)
        // when
        let result = await bound.run(RunRequest(backend: "fixture", repo: "/fixture/repo", prompt: "Fixture prompt"))
        // then
        guard case .failure = result else { Issue.record("Changed selection must prevent launch"); return }
        #expect(runner.calls.map(\.arguments) == [["version-info", "--json"]])
    }

    @Test func givenDifferentSelectedRuntime_whenTaskLaunchUsesEvidence_thenNoCommandOrListingRefresh() async {
        // given
        let runner = StubProcessRunner(output: stdout("{}"))
        let client = CtlClient(executable: "/fixture/original/ctl", environment: [:], runner: runner)
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fixture/replacement/ctl", environment: [:], runner: runner)))
        let tasks = MockTaskListRepository()
        let actions = TaskActionRepositoryImpl(toolEnvironment: environment, taskListRepository: tasks,
                                              snapshotRepository: MockTaskSnapshotRepository())
        // when / then
        do {
            _ = try await actions.run(RunRequest(backend: "fixture", repo: "/fixture/repo", prompt: "Fixture"),
                                      runtime: QualificationRuntimeToken(client: client))
            Issue.record("Changed runtime must refuse launch")
        } catch {
            #expect(QualificationFailure(error: error) == .runtimeChanged)
        }
        #expect(runner.calls.isEmpty)
        verify(tasks).refreshAndWait().called(0)
    }

    @Test func givenDifferentSelectedRuntime_whenWorkflowStarts_thenNoCommandRuns() async {
        // given
        let runner = StubProcessRunner(output: stdout("{}"))
        let client = CtlClient(executable: "/fixture/original/ctl", environment: [:], runner: runner)
        let environment = MockToolEnvironmentRepository()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/fixture/replacement/ctl", environment: [:], runner: runner)))
        let workflows = WorkflowRepositoryImpl(toolEnvironment: environment)
        // when / then
        do {
            _ = try await workflows.command("start", options: ["--prompt=Fixture"], positionals: ["fixture"],
                                            runtime: QualificationRuntimeToken(client: client))
            Issue.record("Changed runtime must refuse workflow start")
        } catch {
            #expect(QualificationFailure(error: error) == .runtimeChanged)
        }
        #expect(runner.calls.isEmpty)
    }
}
