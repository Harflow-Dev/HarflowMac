import Foundation
import Mockable
import MonitorCore
@testable import PbRepository
import PbTestUtilities
import Testing

struct TaskHistoryRetentionTests {
    private func page(_ ids: [String], cursor: String? = nil, flags: [String: JSONValue] = [:], status: String = "completed") -> ProcessOutput {
        var result: [String: JSONValue] = ["items": .array(ids.map { .object(["task_id": .string($0), "status": .string(status)]) }),
            "next_cursor": cursor.map(JSONValue.string) ?? .null, "has_more": .bool(cursor != nil), "bootstrap_pending": .bool(false)]
        result.merge(flags) { _, new in new }
        return stdout(JSONValue.object(["v": .number(5), "result": .object(result)]).rendered())
    }

    @Test func givenOver100LoadedTerminalRows_whenRetentionDeletesThem_thenBoundedRotatingBatchesRemoveOnlyMissingIDs() async {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(page([])) }
            if call.arguments.contains(where: { $0.hasPrefix("--task-ids=") }) { return .success(page([])) }
            if call.arguments.contains("--cursor=older") { return .success(page((0 ..< 100).map { "older-\($0)" }, cursor: "oldest")) }
            if call.arguments.contains("--cursor=oldest") { return .success(page((100 ..< 150).map { "older-\($0)" })) }
            return .success(page(["visible"], cursor: "older"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        await sut.loadMoreHistory()
        #expect(sut.tasks.count == 151)
        await sut.refresh()
        #expect(sut.tasks.count == 51)
        await sut.refresh()
        #expect(sut.tasks.map(\.taskID) == ["visible"])
        let batches = runner.calls.compactMap { $0.arguments.first(where: { $0.hasPrefix("--task-ids=") }) }
        #expect(batches.count == 2)
        #expect(batches.allSatisfy { $0.split(separator: ",").count <= 100 })
        #expect(sut.historyState.nextCursor == nil)
        #expect(sut.detail("older-0") == nil)
    }

    @Test(arguments: ["bootstrap_pending", "authority_incomplete", "history_incomplete", "has_more", "unknown", "failure"])
    func givenUncertainTerminalBatch_whenRevalidating_thenLoadedHistoryIsNotErased(condition: String) async {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") { return .success(page([])) }
            if call.arguments.contains(where: { $0.hasPrefix("--task-ids=") }) {
                if condition == "failure" { return .failure(.unreadable(tool: "fixture", exitCode: 1, stderr: "failed")) }
                if condition == "unknown" { return .success(page(["older"], status: "unknown")) }
                return .success(page([], cursor: condition == "has_more" ? "remaining" : nil, flags: [condition: .bool(true)]))
            }
            if call.arguments.contains("--cursor=older") { return .success(page(["older"])) }
            return .success(page(["visible"], cursor: "older"))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        await sut.refresh()
        #expect(Set(sut.tasks.map(\.taskID)) == ["visible", "older"])
    }

    @Test func givenRetainedConversationFirstMember_whenDeleted_thenPublishedConversationMigratesToSurvivor() async {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--active-only") || call.arguments.contains(where: { $0.hasPrefix("--task-ids=") }) {
                return .success(page([]))
            }
            if call.arguments.contains("--cursor=first") { return .success(page(["first"])) }
            let raw: [String: JSONValue] = ["items": .array([.object(["task_id": .string("survivor"), "status": .string("completed"),
                "parent_task_id": .string("first")])]), "next_cursor": .string("first"), "has_more": .bool(true), "bootstrap_pending": .bool(false)]
            return .success(stdout(JSONValue.object(["v": .number(5), "result": .object(raw)]).rendered()))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        await sut.loadMoreHistory()
        #expect(ConversationIndex(sut.tasks).conversationID(of: "survivor") == "first")
        await sut.refresh()
        #expect(ConversationIndex(sut.tasks).conversationID(of: "survivor") == "survivor")
        #expect(sut.task("first") == nil)
        #expect(sut.detail("first") == nil)
    }

    @Test(arguments: [true, false])
    func givenConversationOnlyTerminalMember_whenRevalidated_thenItUpdatesOrDisappearsWithoutBecomingSidebarHistory(exists: Bool) async throws {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--session-id=conversation") { return .success(page(["member"])) }
            if call.arguments.contains("--task-ids=member") { return .success(page(exists ? ["member"] : [], status: "cancelled")) }
            if call.arguments.contains("--active-only") { return .success(page([])) }
            return .success(page(["visible"]))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        _ = try await sut.conversationPage(sessionID: "conversation", cursor: nil)
        await sut.refresh()
        #expect(sut.tasks.map(\.taskID) == ["visible"])
        #expect((sut.task("member") != nil) == exists)
        if exists {
            #expect(sut.task("member")?.raw["status"]?.stringValue == "cancelled")
        } else {
            #expect(sut.detail("member") == nil)
        }
    }

    @Test(arguments: ["missing", "completed", "cancelled"])
    func givenConcurrentConversationOverlayPromotedActive_whenTerminalBatchReturns_thenItIsRetained(returnedStatus: String) async throws {
        let environment = MockToolEnvironmentRepository()
        given(environment).tasksDirectory.willReturn(FileManager.default.temporaryDirectory.path)
        let promoted = LockedBox(false)
        let entered = LockedBox(false)
        let gate = AsyncGate()
        let runner = StubProcessRunner { call in
            if call.arguments.contains("--session-id=conversation") { return .success(page(["member"], status: promoted.value ? "running" : "completed")) }
            if call.arguments.contains("--task-ids=member") {
                entered.mutate { $0 = true }; gate.waitSync()
                return .success(page(returnedStatus == "missing" ? [] : ["member"], status: returnedStatus))
            }
            if call.arguments.contains("--active-only") { return .success(page([])) }
            return .success(page(["visible"]))
        }
        given(environment).ctl().willReturn(.success(CtlClient(executable: "/bin/echo", environment: [:], runner: runner)))
        let sut = TaskListRepositoryImplTests().makeSUT(toolEnvironment: environment)
        await sut.refresh()
        _ = try await sut.conversationPage(sessionID: "conversation", cursor: nil)
        let refresh = Task { await sut.refresh() }
        await waitUntil { entered.value }
        promoted.mutate { $0 = true }
        _ = try await sut.conversationPage(sessionID: "conversation", cursor: nil)
        gate.open()
        await refresh.value
        #expect(sut.task("member")?.status.isRunning == true)
        #expect(sut.tasks.map(\.taskID) == ["visible"])
    }
}
