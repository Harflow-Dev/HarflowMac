@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - MainWindowCoordinatorGroupTests

@Suite struct MainWindowCoordinatorGroupTests {

    private func task(_ id: String, group: String, parent: String? = nil, session: String = "shared") -> TaskInfo {
        var object: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "group": .string(group), "session_id": .string(session), "started_at": .string("2026-09-30T10:00:00Z")
        ]
        if let parent { object["parent_task_id"] = .string(parent) }
        return TaskInfo(.object(object))!
    }

    @Test func givenAGroupWithOneConversation_whenResolving_thenItIsThatConversationsFirstTask() {
        // given — one agent, resumed once: still one conversation.
        let tasks = [task("a1", group: "solo"), task("a2", group: "solo", parent: "a1")]

        // when
        let id = MainWindowCoordinator.soleConversationID(inGroup: "solo", tasks: tasks)

        // then
        #expect(id == "a1")
    }

    @Test func givenAGroupWithTwoConversations_whenResolving_thenItStaysAParallelRun() {
        // given
        let tasks = [task("a1", group: "pair"), task("b1", group: "pair")]

        // when / then
        #expect(MainWindowCoordinator.soleConversationID(inGroup: "pair", tasks: tasks) == nil)
    }

    @Test(arguments: [true, false])
    func givenOneLineageWithHarnessSessions_whenOpeningParent_thenOnlyOneActualSessionUsesTaskDetail(sameSession: Bool) {
        // given
        let tasks = [task("a1", group: "sessions", session: "first"),
                     task("a2", group: "sessions", parent: "a1", session: sameSession ? "first" : "fresh")]
        // when
        let detailID = MainWindowCoordinator.soleConversationID(inGroup: "sessions", tasks: tasks)
        // then — nil selects the parallel screen; a sole session selects task detail.
        #expect(detailID == (sameSession ? "a1" : nil))
    }

    @Test func givenAnUnknownGroup_whenResolving_thenThereIsNoTask() {
        // given / when / then
        #expect(MainWindowCoordinator.soleConversationID(inGroup: "missing", tasks: [task("a1", group: "solo")]) == nil)
    }
}
