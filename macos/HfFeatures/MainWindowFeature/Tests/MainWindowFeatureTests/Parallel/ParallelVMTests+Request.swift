import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - View prompt reads

extension ParallelVMTests {
    /// The request-read surface of the use case: states per task, a subject per task, and every read recorded.
    @MainActor struct RequestStub {
        let states = Box<[String: TaskRequestReadState]>([:])
        let subjects = Box<[String: CurrentValueSubject<TaskRequestReadState, Never>]>([:])
        let reads = Box<[String]>([])

        func subject(_ id: String) -> CurrentValueSubject<TaskRequestReadState, Never> {
            if let existing = subjects.value[id] { return existing }
            let created = CurrentValueSubject<TaskRequestReadState, Never>(states.value[id] ?? .notRequested)
            subjects.value[id] = created
            return created
        }

        func set(_ id: String, _ state: TaskRequestReadState) {
            states.value[id] = state
            subject(id).send(state)
        }
    }

    @discardableResult func stubRequests(_ harness: SUT) -> RequestStub {
        let stub = harness.requests
        given(harness.routing).copyToPasteboard(.any).willReturn(true)
        given(harness.useCase).requestState(for: .any).willProduce { stub.states.value[$0] ?? .notRequested }
        given(harness.useCase).requestPublisher(for: .any).willProduce { stub.subject($0).eraseToAnyPublisher() }
        given(harness.useCase).readRequest(for: .any, maxBytes: .any).willProduce { id, _ in
            stub.reads.value.append(id)
            stub.set(id, .loading(maxBytes: 65536))
        }
        return stub
    }

    private func appear(_ harness: SUT, ids: [String]) async {
        let tasks = ids.enumerated().map { task(id: $0.element, startedAt: Date(timeIntervalSince1970: Double($0.offset + 1))) }
        for item in tasks { harness.tasksBox.value[item.taskID] = item }
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == ids.count && harness.sut.isPresentationSettled && harness.sut.leasedMemberCount == ids.count }
    }

    @Test func givenViewPromptIsOff_whenLanesLease_thenNothingIsRead() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests

        // when
        await appear(harness, ids: ["a", "b"])

        // then
        #expect(stub.reads.value.isEmpty)
        #expect(harness.sut.requestStates.isEmpty)
        #expect(harness.sut.columns.allSatisfy { $0.request == nil })
        harness.sut.didDisappear()
    }

    @Test func givenViewPromptTurnsOn_whenLanesAreResident_thenEachLaneReadsItsPromptTaskOnce() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests
        await appear(harness, ids: ["a", "b"])

        // when
        harness.sut.didTapViewPrompt()
        await waitUntil { stub.reads.value.count == 2 && harness.sut.columns.allSatisfy { $0.request == .loading(maxBytes: 65536) } }

        // then
        #expect(Set(stub.reads.value) == ["a", "b"])
        #expect(harness.sut.columns.allSatisfy { $0.request == .loading(maxBytes: 65536) && $0.onReadRequest != nil })
        harness.sut.didDisappear()
    }

    @Test func givenARead_whenViewPromptTogglesOffAndOn_thenNothingIsReadAgain() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests
        await appear(harness, ids: ["a"])
        harness.sut.didTapViewPrompt()
        await waitUntil { stub.reads.value.count == 1 }

        // when
        harness.sut.didTapViewPrompt()
        harness.sut.didTapViewPrompt()
        await waitUntil { harness.sut.columns.first?.request != nil }

        // then — the stored state is not `.notRequested`, so no second read starts
        #expect(stub.reads.value == ["a"])
        harness.sut.didDisappear()
    }

    @Test func givenViewPromptTurnsOff_whenTheRequestChanges_thenTheSubscriptionIsGoneAndTheColumnShowsNone() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests
        await appear(harness, ids: ["a"])
        harness.sut.didTapViewPrompt()
        await waitUntil { harness.sut.columns.first?.request == .loading(maxBytes: 65536) }

        // when
        harness.sut.didTapViewPrompt()
        stub.set("a", .notRequested)
        await Task.yield()

        // then
        #expect(harness.sut.requestSubscriptions.isEmpty)
        #expect(harness.sut.columns.first?.request == nil)
        harness.sut.didDisappear()
    }

    @Test func givenAConversationWithTwoMembers_whenTheSecondLeaseArrives_thenThePromptIsNotReadAgain() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests
        let first = task(id: "first", status: "completed", startedAt: Date(timeIntervalSince1970: 1))
        let reply = task(id: "reply", startedAt: Date(timeIntervalSince1970: 2), parentTaskID: "first")
        harness.tasksBox.value = ["first": first, "reply": reply]
        harness.sut.didAppear()
        harness.tasksSubject.send([first, reply])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled && harness.sut.leasedMemberCount == 2 }

        // when
        harness.sut.didTapViewPrompt()
        await waitUntil { stub.reads.value.count == 1 }
        harness.snapshotsSubject.send(["reply": reply])
        await Task.yield()

        // then — the lane reads its first member only, once
        #expect(stub.reads.value == ["first"])
        harness.sut.didDisappear()
    }

    @Test func givenAViewportOfOneLane_whenViewPromptTurnsOn_thenOnlyTheResidentLaneReads() async {
        // given
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: ParallelTestGeometry.laneStride)
        let stub = harness.requests
        let tasks = (0 ..< 4).map { task(id: "task-\($0)", startedAt: Date(timeIntervalSince1970: Double($0))) }
        for item in tasks { harness.tasksBox.value[item.taskID] = item }
        harness.sut.didAppear()
        harness.tasksSubject.send(tasks)
        await waitUntil { harness.sut.columns.count == 4 && harness.sut.isPresentationSettled }

        // when
        harness.sut.didTapViewPrompt()
        await waitUntil { stub.reads.value.count == harness.sut.residentColumnCount && harness.sut.residentColumnCount > 0 }

        // then — scrolling another lane in triggers its read
        let first = stub.reads.value
        #expect(first.count == harness.sut.residentColumnCount)
        #expect(first.count < 4)
        harness.sut.updateViewport(offset: ParallelTestGeometry.laneStride * 3, width: ParallelTestGeometry.laneStride)
        await waitUntil { stub.reads.value.count > first.count }
        #expect(Set(stub.reads.value).count == stub.reads.value.count)
        harness.sut.didDisappear()
    }

    @Test func givenAnOpenRead_whenTheViewDisappears_thenSubscriptionsAndStatesAreDroppedAndALateResultIsIgnored() async {
        // given
        let harness = makeSUT()
        let stub = harness.requests
        await appear(harness, ids: ["a"])
        harness.sut.didTapViewPrompt()
        await waitUntil { stub.reads.value.count == 1 }

        // when
        harness.sut.didDisappear()
        stub.set("a", .failed(ToolError.unsupportedCommand(tool: "harflow-ctl", command: "request", detail: "late"), maxBytes: 65536))
        await Task.yield()

        // then
        #expect(harness.sut.requestSubscriptions.isEmpty)
        #expect(harness.sut.requestStates.isEmpty)
    }

    @Test func givenARequestBeforeAnyLease_whenViewPromptTurnsOn_thenNoStateIsHeld() async {
        // given — the viewport is unknown, so no lane is resident and none is leased
        let harness = makeSUT()
        harness.sut.updateViewport(offset: 0, width: 0)
        let stub = harness.requests
        let item = task(id: "a")
        harness.tasksBox.value["a"] = item
        harness.sut.didAppear()
        harness.tasksSubject.send([item])
        await waitUntil { harness.sut.columns.count == 1 && harness.sut.isPresentationSettled }

        // when
        harness.sut.didTapViewPrompt()

        // then
        #expect(harness.sut.leasedMemberCount == 0)
        #expect(harness.sut.requestStates.isEmpty)
        #expect(stub.reads.value.isEmpty)
        harness.sut.didDisappear()
    }

    // MARK: - Outcome announcements across appearances

    @Test func givenAnOutcomeWasAnnounced_whenTheUserLeavesAndReturnsToTheGroup_thenItIsNotAnnouncedAgain() async {
        // given
        let harness = makeSUT()
        await appear(harness, ids: ["a"])
        let first = harness.sut.columnState(for: "a")
        #expect(first.shouldAnnounce(outcome: "Queued message cancelled.") == true)

        // when — the per-appearance UI state is discarded and rebuilt
        harness.sut.didDisappear()
        await appear(harness, ids: ["a"])
        let second = harness.sut.columnState(for: "a")

        // then
        #expect(second !== first)
        #expect(second.shouldAnnounce(outcome: "Queued message cancelled.") == false)
        #expect(second.shouldAnnounce(outcome: "Delivery is in progress.") == true)
        harness.sut.didDisappear()
    }

    @Test func givenTwoLanesWithTheSameOutcome_whenEachAnnounces_thenTheMemoryIsKeyedByConversation() async {
        // given
        let harness = makeSUT()
        await appear(harness, ids: ["a", "b"])

        // when / then
        #expect(harness.sut.columnState(for: "a").shouldAnnounce(outcome: "Queued message cancelled.") == true)
        #expect(harness.sut.columnState(for: "b").shouldAnnounce(outcome: "Queued message cancelled.") == true)
        #expect(harness.sut.columnState(for: "a").shouldAnnounce(outcome: "Queued message cancelled.") == false)
        harness.sut.didDisappear()
    }
}
