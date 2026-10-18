import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
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
            finishNotifier: NullFinishNotifier(), scheduler: NullScheduling(), visibility: NullMonitorVisibility())
        let sut = TaskDetailViewRepository(taskListRepository: listing)
        let page = try await sut.conversationHistory(sessionID: "session", cursor: "older")
        #expect(page?.items.map(\.taskID) == ["turn"])
        let calls = await runner.calls
        let operationCalls = calls.filter { $0.first != "version-info" }
        #expect(operationCalls.count == 1)
        #expect(operationCalls.first?.contains("--session-id=session") == true)
        #expect(operationCalls.first?.contains("--cursor=older") == true)
        #expect(operationCalls.first?.contains("--limit=100") == true)
        #expect(sut.task("turn")?.taskID == "turn")
        // The convenience overload must also forward through the protocol witness.
        let direct = try await listing.conversationPage(sessionID: "session", cursor: nil)
        #expect(direct.items.map(\.taskID) == ["turn"])
        let allCalls = await runner.calls
        #expect(allCalls.filter { $0.first != "version-info" }.count == 2)
    }
}

private actor ConversationPageRunner: ProcessRunning {
    var calls: [[String]] = []
    func run(executable: String, arguments: [String], environment: [String: String],
             currentDirectory: String?, timeout: Double) async -> Result<ProcessOutput, ToolError> {
        calls.append(arguments)
        let json = if arguments == ["version-info", "--json"] {
            "{\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1,\"product_version\":\"1.0.0\","
                + "\"component\":\"engine\",\"state_root\":\"\(NSHomeDirectory())/.harflow\","
                + "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1},"
                + "\"events\":{\"format\":\"harflow.event\",\"v\":1}},"
                + "\"capabilities\":[\"ctl.v1\",\"events.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
        } else {
            #"{"product":"harflow","format":"harflow.ctl","v":1,"product_version":"1.0.0","result":{"items":["#
                + #"{"task_id":"turn","session_id":"session"}],"#
                + #""next_cursor":null,"has_more":false,"bootstrap_pending":false}}"#
        }
        return .success(ProcessOutput(exitCode: 0, stdout: Data(json.utf8), stderr: "", timedOut: false))
    }
}
