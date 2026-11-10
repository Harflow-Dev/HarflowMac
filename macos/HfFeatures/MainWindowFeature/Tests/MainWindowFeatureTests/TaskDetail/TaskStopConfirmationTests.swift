import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct TaskStopConfirmationTests {
    @Test func givenStandaloneRunningTask_whenStopConfirmed_thenCapturedTaskIsCancelled() async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        var request: TaskStopConfirmation?
        given(harness.routing)
.presentStopConfirmation(.any)
.willProduce { request = $0 }
        harness.detailBox.value = TaskDetailVMTests().task()
        harness.sut.didAppear()
        harness.tasksSubject.send([TaskDetailVMTests().task()])
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.canCancel }
        // when
        harness.sut.didTapCancel()
        request?.confirm()
        // then
        #expect(request?.taskID == "abc12345")
        await verify(harness.useCase).cancel(.value("abc12345")).calledEventually(1, before: .seconds(5))
    }

    @Test func givenNewConversationTurn_whenOldStopConfirmed_thenRefusalIsDurable() async {
        // given
        let fixtures = TaskDetailVMTests()
        let first = fixtures.conversationTask("a", status: "running")
        let next = fixtures.conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let harness = fixtures.makeConversationSUT(openedAs: "a", initialMembers: [first], stubbedMembers: [first, next], chrome: .standalone)
        var request: TaskStopConfirmation?
        given(harness.routing)
.presentStopConfirmation(.any)
.willProduce { request = $0 }
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.canCancel }
        harness.sut.didTapCancel()
        // when
        harness.membersBox.value = [first, next]
        harness.tasksSubject.send([first, next])
        await waitUntil { harness.sut.currentTaskID == "b" }
        request?.confirm()
        // then
        verify(harness.useCase).setOutcome(.value("b"), .value("The conversation moved on — review and try again.")).called(1)
        verify(harness.useCase).cancel(.any).called(0)
    }

    @Test func givenBusyStandaloneTask_whenStopRequested_thenNoConfirmationIsPresented() async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        harness.detailBox.value = TaskDetailVMTests().task()
        harness.sut.didAppear()
        harness.tasksSubject.send([TaskDetailVMTests().task()])
        defer { harness.sut.didDisappear() }
        harness.busySubject.send(["abc12345"])
        await waitUntil { harness.sut.isBusy }
        // when
        harness.sut.didTapCancel()
        // then
        verify(harness.routing).presentStopConfirmation(.any).called(0)
    }

    @Test func givenEarlierTurnDescendantOutsideCurrentScope_whenStopRequested_thenOnlyRunningExclusionsAreNamed() async {
        // given
        let fixtures = TaskDetailVMTests()
        let first = fixtures.conversationTask("a")
        let current = fixtures.conversationTask("b", status: "running", parentTaskID: "a", minute: 1)
        let earlierChild = fixtures.conversationTask("child", status: "running", spawnedBy: "a")
        let finished = fixtures.conversationTask("finished", spawnedBy: "a")
        let members = [first, current, earlierChild, finished]
        let harness = fixtures.makeConversationSUT(openedAs: "a", initialMembers: members, chrome: .standalone)
        harness.cancelScopeBox.value = { $0 == "a" ? ["a", "b", "child", "finished"] : [$0] }
        var request: TaskStopConfirmation?
        given(harness.routing)
.presentStopConfirmation(.any)
.willProduce { request = $0 }
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.currentTaskID == "b" }
        // when
        harness.sut.didTapCancel()
        // then
        #expect(request?.taskID == "b")
        #expect(request?.notStoppedTitles == ["Task child"])
    }

    @Test func givenPendingStop_whenTaskEndsBeforeConfirmation_thenEngineIsNotCalled() async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        var request: TaskStopConfirmation?
        given(harness.routing)
.presentStopConfirmation(.any)
.willProduce { request = $0 }
        harness.detailBox.value = TaskDetailVMTests().task()
        harness.sut.didAppear()
        harness.tasksSubject.send([TaskDetailVMTests().task()])
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.canCancel }
        harness.sut.didTapCancel()
        // when
        let completed = TaskDetailVMTests().task(status: "completed")
        harness.detailBox.value = completed
        harness.tasksSubject.send([completed])
        await waitUntil { !harness.sut.canCancel }
        request?.confirm()
        // then
        verify(harness.useCase).cancel(.any).called(0)
    }

    @Test(arguments: [TaskDetailChrome.standalone, .group, .embedded])
    func givenRunningTask_whenComposerComputed_thenStopBelongsOnlyToStandalone(chrome: TaskDetailChrome) async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: chrome)
        harness.detailBox.value = TaskDetailVMTests().task()
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.canCancel }
        // when
        let model = harness.sut.messageBoxModel
        // then
        #expect((model.stopAction != nil) == (chrome == .standalone))
    }

    @Test func givenTakenOverTask_whenComposerComputed_thenStopIsAbsent() async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        harness.detailBox.value = TaskDetailVMTests().task(takenOver: true)
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.canCancel }
        // when
        let model = harness.sut.messageBoxModel
        // then
        #expect(model.isLocked)
        #expect(model.stopAction == nil)
    }

    @Test func givenBusyComposer_whenComputed_thenStopRemainsPresentAndBusy() async {
        // given
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone)
        harness.detailBox.value = TaskDetailVMTests().task()
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        harness.busySubject.send(["abc12345"])
        await waitUntil { harness.sut.isBusy }
        // when
        let model = harness.sut.messageBoxModel
        // then
        #expect(model.stopAction != nil)
        #expect(model.isBusy)
    }

    @Test func givenNativeControlTask_whenComposerComputed_thenStopIsAbsent() async throws {
        // given
        let fixtures = TaskDetailVMTests()
        let harness = fixtures.makeSUT(chrome: .standalone)
        var raw = fixtures.task().raw
        raw["workflow_role"] = .string("native_control")
        harness.detailBox.value = try #require(TaskInfo(.object(raw)))
        harness.sut.didAppear()
        defer { harness.sut.didDisappear() }
        await waitUntil { harness.sut.task != nil }
        // when
        let model = harness.sut.messageBoxModel
        // then
        #expect(model.stopAction == nil)
    }

}
