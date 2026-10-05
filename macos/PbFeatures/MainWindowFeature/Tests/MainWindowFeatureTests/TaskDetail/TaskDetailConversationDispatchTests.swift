import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTestUtilities
import Testing

@MainActor
struct TaskDetailConversationDispatchTests {
    @Test func givenConcreteTaskListBehindProtocol_whenDetailLoadsConversation_thenSessionPageCLIIsCalled() async throws {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn("/isolated/tasks")
        let runner = ConversationPageRunner()
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let listing: any TaskListRepository = TaskListRepositoryImpl(toolEnvironment: environment,
            snapshotRepository: NullTaskSnapshotRepository(), eventStreamRepository: NullEventStreamRepository(),
            finishNotifier: NullFinishNotifier(), scheduler: NullScheduling())
        let sut = TaskDetailViewRepository(taskListRepository: listing)
        let page = try await sut.conversationHistory(sessionID: "session", cursor: "older")
        #expect(page?.items.map(\.taskID) == ["turn"])
        let calls = await runner.calls
        #expect(calls.count == 1)
        #expect(calls.first?.contains("--session-id=session") == true)
        #expect(calls.first?.contains("--cursor=older") == true)
        #expect(calls.first?.contains("--limit=100") == true)
        #expect(sut.task("turn")?.taskID == "turn")
        // The convenience overload must also forward through the protocol witness.
        let direct = try await listing.conversationPage(sessionID: "session", cursor: nil)
        #expect(direct.items.map(\.taskID) == ["turn"])
        #expect(await runner.calls.count == 2)
    }
}

private actor ConversationPageRunner: ProcessRunning {
    var calls: [[String]] = []
    func run(executable: String, arguments: [String], environment: [String: String],
             currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        calls.append(arguments)
        let json = #"{"v":5,"result":{"items":[{"task_id":"turn","session_id":"session"}],"next_cursor":null,"has_more":false,"bootstrap_pending":false}}"#
        return .success(ProcessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: "", timedOut: false))
    }
}
