import AppKit
import Combine
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

@MainActor @Suite struct GroupPresentationTests {
    @Test func givenCompletedFirstAndRunningSecond_whenMembershipIsBuilt_thenBothConversationsArePresented() {
        // given
        let tasks = [task("first", status: "completed"), task("second", status: "running")]

        // when
        let presentation = GroupMembershipPresentation.build(name: "group", tasks: tasks)

        // then
        #expect(presentation.conversations == [["first"], ["second"]])
    }

    @Test func givenAResumedLineage_whenMembershipIsBuilt_thenTheLineageRemainsOneConversation() {
        // given
        let tasks = [task("first", status: "completed", session: "shared"),
                     task("resume", status: "completed", parent: "first", session: "shared")]

        // when
        let presentation = GroupMembershipPresentation.build(name: "group", tasks: tasks)

        // then
        #expect(presentation.conversations == [["first", "resume"]])
        #expect(presentation.parents == ["resume": "first"])
    }

    @Test func givenAParentWithANewHarnessSession_whenMembershipIsBuilt_thenItStartsANewConversation() {
        // given
        let tasks = [task("first", status: "completed", session: "old"),
                     task("replacement", status: "running", parent: "first", session: "new")]

        // when
        let presentation = GroupMembershipPresentation.build(name: "group", tasks: tasks)

        // then
        #expect(presentation.conversations == [["first"], ["replacement"]])
    }

    @Test func givenAGroupWithoutParallelMembership_whenMembershipIsBuilt_thenNoConversationIsPresented() {
        // given / when
        let presentation = GroupMembershipPresentation.build(name: "missing", tasks: [task("first")])

        // then
        #expect(presentation.conversations.isEmpty)
    }

    @Test func givenMountedSingleton_whenSecondConversationPublishes_thenParallelPromotionSeedsTheExistingActivity() async throws {
        // given
        let first = task("first", status: "completed", session: "shared")
        let second = task("second", status: "running", session: "new")
        let detailHarness = TaskDetailVMTests().makeSUT(taskID: "first")
        detailHarness.detailBox.value = first
        let historyEvent = TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":0,"kind":"assistant_text","text":"retained history"}"#)!
        detailHarness.eventsBox.value = [historyEvent]
        detailHarness.itemsOverride.value = Timeline.items(from: [historyEvent])
        let parallelHarness = ParallelVMTests().makeSUT(groupName: "group")
        parallelHarness.eventsBox.value["first"] = [historyEvent]
        parallelHarness.itemsBox.value["first"] = Timeline.items(from: [historyEvent])
        parallelHarness.availabilityBox.value["first"] = .available
        let itemUpdates = PassthroughSubject<[TimelineItem], Never>()
        parallelHarness.itemSubjectsBox.value["first"] = itemUpdates
        let tasks = CurrentValueSubject<[TaskInfo], Never>([first])
        let useCase = MockGroupPresentationUseCase()
        given(useCase).tasksPublisher().willReturn(tasks.eraseToAnyPublisher())
        let sut = GroupPresentationVM(groupName: "group", useCase: useCase,
                                      makeDetail: { _ in detailHarness.sut },
                                      makeParallel: { parallelHarness.sut })
        _ = NSApplication.shared
        let host = NSHostingView(rootView: GroupPresentationView(sut).frame(width: 900, height: 600))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.contentView = nil
            window.close()
            sut.didDisappear()
            detailHarness.sut.didDisappear()
            parallelHarness.sut.didDisappear()
        }
        try await waitUntil { sut.detailVM === detailHarness.sut }
        sut.activityState.expandedGroups = ["retained-tool"]
        detailHarness.sut.didAppear()
        try await waitUntil {
            detailHarness.sut.exportConversationActivity()?.presentation?.rows.isEmpty == false
        }
        let retainedState = sut.activityState
        var paused = retainedState.followLive
        paused.suspend()
        retainedState.followLive = paused

        // when
        tasks.send([first, second])
        try await waitUntil { sut.parallelVM === parallelHarness.sut }

        // then
        #expect(sut.detailVM == nil)
        #expect(sut.hasPromotedActivity)
        #expect(sut.activityState === retainedState)
        #expect(parallelHarness.sut.columnState(for: "first") === retainedState)
        #expect(retainedState.expandedGroups == ["retained-tool"])
        #expect(retainedState.followLive.isFollowing == false)

        try await assertReacquiredLane(parallelHarness, state: retainedState,
                                       members: (first, second),
                                       historyEvent: historyEvent, itemUpdates: itemUpdates)
        host.layoutSubtreeIfNeeded()
        capture(host, to: "/private/tmp/harflow-issues3-5/group-promotion.png")

        try await assertParallelRetention(sut, tasks: tasks, first: first, second: second)
    }

    private func assertParallelRetention(
        _ sut: GroupPresentationVM, tasks: CurrentValueSubject<[TaskInfo], Never>,
        first: TaskInfo, second: TaskInfo
    ) async throws {
        let promoted = sut.parallelVM
        tasks.send([first])
        tasks.send([first, second])
        try await waitUntil { sut.parallelVM === promoted }
        #expect(sut.parallelVM === promoted)
    }

    private func assertReacquiredLane(
        _ harness: ParallelVMTests.SUT, state: ParallelColumnUIState, members: (TaskInfo, TaskInfo),
        historyEvent: TaskEvent, itemUpdates: PassthroughSubject<[TimelineItem], Never>
    ) async throws {
        let (first, second) = members
        harness.tasksBox.value["first"] = first
        harness.sut.didAppear()
        harness.tasksBox.value["second"] = second
        harness.tasksSubject.send([first, second])
        try await waitUntil {
            harness.sut.isPresentationSettled && harness.sut.columns.first?.rows.isEmpty == false
        }
        #expect(harness.sut.columnState(for: "first") === state)
        #expect(state.expandedGroups == ["retained-tool"])
        #expect(state.followLive.isFollowing == false)
        #expect(Set(harness.sut.columns.map(\.id)) == Set(["first", "second"]))
        let initialRowCount = harness.sut.columns.first?.rows.count ?? 0
        let appendedEvent = TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":1,"kind":"assistant_text","text":"new output"}"#)!
        itemUpdates.send(Timeline.items(from: [historyEvent, appendedEvent]))
        try await waitUntil { (harness.sut.columns.first?.rows.count ?? 0) > initialRowCount }
    }

    private func capture(_ host: NSView, to path: String) {
        let bounds = host.bounds
        guard let rep = host.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        host.cacheDisplay(in: bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    @Test func givenMountedSingleton_whenOldestTaskIsPrunedAndSameSessionChildRemains_thenDetailTracksTheChild() async throws {
        // given
        let first = task("first", status: "completed", session: "shared")
        let child = task("child", status: "running", parent: "first", session: "shared")
        let detailHarness = TaskDetailVMTests().makeConversationSUT(
            openedAs: "first", initialMembers: [first], stubbedMembers: [first, child])
        let tasks = CurrentValueSubject<[TaskInfo], Never>([first])
        let useCase = MockGroupPresentationUseCase()
        given(useCase).tasksPublisher().willReturn(tasks.eraseToAnyPublisher())
        let sut = GroupPresentationVM(groupName: "group", useCase: useCase,
                                      makeDetail: { _ in detailHarness.sut },
                                      makeParallel: { ParallelVMTests().makeSUT(groupName: "group").sut })
        defer {
            sut.didDisappear()
            detailHarness.sut.didDisappear()
        }
        sut.didAppear()
        try await waitUntil { sut.detailVM === detailHarness.sut }
        detailHarness.sut.didAppear()
        try await waitUntil { detailHarness.sut.currentTaskID == "first" }

        // when — the repository atomically publishes the surviving child and the detail VM sees
        // the same listing, forcing its identity to follow the oldest surviving member.
        detailHarness.membersBox.value = [child]
        detailHarness.tasksSubject.send([child])
        tasks.send([child])
        try await waitUntil { detailHarness.sut.currentTaskID == "child" }

        // then
        #expect(sut.detailVM === detailHarness.sut)
        #expect(sut.detailIdentity == "first")
        #expect(detailHarness.sut.currentTaskID == "child")
    }

    private func task(_ id: String, status: String = "completed", parent: String? = nil,
                      session: String? = nil) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(id), "group": .string("group"), "session_id": .string(session ?? id),
            "backend": .string("codex"), "repo_path": .string("/repo"), "status": .string(status),
            "started_at": .string("2026-01-01T00:00:00Z")
        ]
        if let parent { raw["parent_task_id"] = .string(parent) }
        return TaskInfo(.object(raw))!
    }
}
