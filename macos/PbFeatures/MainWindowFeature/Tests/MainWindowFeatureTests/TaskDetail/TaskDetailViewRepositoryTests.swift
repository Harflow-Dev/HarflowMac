import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbRepository
import PbTerminal
import PbTestUtilities
import Testing

/// A tiny lock-protected box: the closure Swift Testing runs concurrently must not mutate a plain
/// captured `var` directly, and `onResumed` is declared `@escaping @Sendable`.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Value
    init(_ value: Value) { self._value = value }
    var value: Value {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    
    func mutate(_ body: (inout Value) -> Void) {
        lock.lock(); defer { lock.unlock() }
        body(&_value)
    }
}

@MainActor
@Suite struct TaskDetailViewRepositoryTests {
    
    @Test func givenListingQueries_whenCalled_thenTheyForwardToTaskListRepository() {
        // given
        let taskList = MockTaskListRepository()
        given(taskList).detail(.value("abc123")).willReturn(nil)
        given(taskList).task(.value("abc123")).willReturn(nil)
        given(taskList).title(.value("abc123")).willReturn("Fix the bug")
        let sut = TaskDetailViewRepository(taskListRepository: taskList)
        
        // then
        #expect(sut.detail("abc123") == nil)
        #expect(sut.task("abc123") == nil)
        #expect(sut.title("abc123") == "Fix the bug")
        verify(taskList).detail(.value("abc123")).called(1)
    }
    
    @Test func givenLineageQueries_whenCalled_thenTheyDeriveFromTheListingTasks() {
        // given
        let taskList = MockTaskListRepository()
        let parent = task(id: "parent", spawnedBy: nil)
        let child = task(id: "child", spawnedBy: "parent")
        let sibling = task(id: "sibling", spawnedBy: "parent")
        given(taskList).tasks.willReturn([parent, child, sibling])
        let sut = TaskDetailViewRepository(taskListRepository: taskList)
        
        // when / then
        #expect(sut.ancestors(of: "child").map(\.taskID) == ["parent"])
        #expect(sut.children(of: "parent").map(\.taskID) == ["child", "sibling"])
        #expect(Set(sut.siblings(of: "child").map(\.taskID)) == ["child", "sibling"])
        #expect(sut.siblings(of: "parent").isEmpty) // a root task has no siblings
    }
    
    @Test func givenSnapshotQueries_whenCalled_thenTheyForwardToTaskSnapshotRepository() async {
        // given
        let snapshots = MockTaskSnapshotRepository()
        given(snapshots).snapshot(.value("abc123")).willReturn(nil)
        given(snapshots).refresh(.value("abc123")).willReturn()
        let sut = TaskDetailViewRepository(taskSnapshotRepository: snapshots)
        
        // when
        await sut.refreshSnapshot("abc123")
        
        // then
        #expect(sut.snapshot("abc123") == nil)
        verify(snapshots).refresh(.value("abc123")).called(1)
    }
    
    @Test func givenActionCalls_whenDispatched_thenTheyForwardToTaskActionRepository() async throws {
        // given
        let actions = MockTaskActionRepository()
        given(actions).cancel(.value("abc123")).willReturn(true)
        given(actions).send(.value("abc123"), text: .value("hi")).willReturn(true)
        // The `onResumed` closure passed through `sut.resume` must reach `actions.resume` itself
        // (not be dropped or replaced) — invoking the forwarded closure here proves that.
        let resumedID = LockedBox<String?>(nil)
        given(actions).resume(.value("abc123"), text: .value("hi"), onResumed: .any).willProduce { _, _, onResumed in
            Task { await onResumed("def456") }
            return "def456"
        }
        let sut = TaskDetailViewRepository(taskActionRepository: actions)
        
        // when / then
        #expect(try await sut.cancel("abc123") == true)
        #expect(try await sut.send("abc123", text: "hi") == true)
        #expect(try await sut.resume("abc123", text: "hi") { id in resumedID.mutate { $0 = id } } == "def456")
        await waitUntil { resumedID.value == "def456" }
        #expect(resumedID.value == "def456")
    }
    
    @Test func givenBeginTakeover_whenCalled_thenItForwardsToTakeoverService() {
        // given
        let takeover = MockTakeoverService()
        var capturedTaskID: String?
        var capturedDestination: TakeoverDestination?
        given(takeover)
            .beginTakeover(taskID: .any, destination: .any)
            .willProduce { taskID, destination in
                capturedTaskID = taskID
                capturedDestination = destination
            }
        let sut = TaskDetailViewRepository(takeoverService: takeover)
        
        // when
        sut.beginTakeover(taskID: "abc123", destination: .terminalApp)
        
        // then
        #expect(capturedTaskID == "abc123")
        if case .terminalApp = capturedDestination {} else { Issue.record("expected .terminalApp, got \(String(describing: capturedDestination))") }
    }
    
    @Test func givenSessionQueries_whenCalled_thenTheyForwardToTheSessionRegistry() throws {
        // given
        let registry = MockTerminalSessionRegistry()
        given(registry).session(forTask: .value("abc123")).willReturn(nil)
        given(registry).remove(.any).willReturn()
        let sut = TaskDetailViewRepository(terminalSessionRegistry: registry)
        let session = TerminalSession(
            kind: .interactive, title: "claude", backend: "claude",
            command: try TakeoverWrapper.command(argv: ["/bin/cat"], cwd: "/tmp", environment: [:])
        )
        
        // when
        sut.removeSession(session)
        
        // then
        #expect(sut.session(forTask: "abc123") == nil)
        verify(registry).remove(.any).called(1)
    }
    
    @Test func givenEventStreamQueries_whenCalled_thenTheyForwardToEventStreamRepository() {
        // given
        let events = MockEventStreamRepository()
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn("abc123")
        given(events).acquire(.value("abc123")).willReturn(lease)
        given(events).items(for: .value("abc123")).willReturn([])
        given(events).itemsPublisher(for: .value("abc123")).willReturn(Just([]).eraseToAnyPublisher())
        given(events).events(for: .value("abc123")).willReturn([])
        given(events).activity(for: .value("abc123")).willReturn(ActivityCounts())
        given(events).current(for: .value("abc123")).willReturn(nil)
        given(events).prompt(for: .value("abc123")).willReturn("Fix the bug")
        let sut = TaskDetailViewRepository(eventStreamRepository: events)
        
        // when
        let acquired = sut.acquireEventLease("abc123")
        
        // then
        #expect(acquired.taskID == "abc123")
        #expect(sut.items(for: "abc123").isEmpty)
        #expect(sut.events(for: "abc123").isEmpty)
        #expect(sut.activity(for: "abc123") == ActivityCounts())
        #expect(sut.current(for: "abc123") == nil)
        #expect(sut.prompt(for: "abc123") == "Fix the bug")
    }
    
    @Test func givenEventsPath_whenComputed_thenItUsesTheToolEnvironmentsTasksDirectory() {
        // given
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).tasksDirectory.willReturn("/tmp/pb-tasks")
        let sut = TaskDetailViewRepository(toolEnvironmentRepository: toolEnvironment)
        
        // when
        let path = sut.eventsPath(for: "abc12345")
        
        // then
        #expect(path == "/tmp/pb-tasks/abc12345.events.jsonl")
    }
    
    @Test func givenGitChanges_whenAsked_thenItForwardsToGitChangesRepositoryWithTheResolvedEnvironment() async {
        // given
        let git = MockGitChangesRepository()
        let toolEnvironment = MockToolEnvironmentRepository()
        given(toolEnvironment).environment(toolDirectory: .any).willReturn(["PATH": "/usr/bin"])
        let expected = GitChanges(files: [], diffs: [], commitsSinceBase: nil, branch: "main", labels: [], comparedWithBase: true)
        given(git)
            .changes(
                repo: .value("/repo"), baseCommit: .value("abc"), startDirty: .value(false), environment: .value(["PATH": "/usr/bin"])
            )
            .willReturn(expected)
        let sut = TaskDetailViewRepository(gitChangesRepository: git, toolEnvironmentRepository: toolEnvironment)
        
        // when
        let result = await sut.gitChanges(repo: "/repo", baseCommit: "abc", startDirty: false)
        
        // then
        #expect(result == expected)
    }
    
    @Test func givenPreviewFile_whenAsked_thenItForwardsToFilePreviewRepository() async {
        // given
        let preview = MockFilePreviewRepository()
        given(preview).preview(repo: .value("/repo"), path: .value("a.txt")).willReturn(.text("hello"))
        let sut = TaskDetailViewRepository(filePreviewRepository: preview)
        
        // when
        let result = await sut.previewFile(repo: "/repo", path: "a.txt")
        
        // then
        #expect(result == .text("hello"))
    }
    
    @Test func givenSchedule_whenCalled_thenItForwardsToScheduling() {
        // given
        let scheduling = MockScheduling()
        given(scheduling).schedule(after: .value(10), execute: .any).willReturn(AnyCancellable {})
        let sut = TaskDetailViewRepository(scheduling: scheduling)
        
        // when
        _ = sut.schedule(after: 10) {}
        
        // then
        verify(scheduling).schedule(after: .value(10), execute: .any).called(1)
    }
    
    // MARK: - Fixtures
    
    private func task(id: String, spawnedBy: String?, status: String = "running") -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string(id), "backend": .string("claude"), "status": .string(status)]
        if let spawnedBy { object["spawned_by"] = .string(spawnedBy) }
        return TaskInfo(.object(object))!
    }
}
