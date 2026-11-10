import Foundation
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Independent read authorities

extension TaskStatusUnavailableTests {
    func drainStatusActions() async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in continuation.resume() }
        }
    }

    @Test func givenNewCurrentMemberWithFailedRead_whenConversationMoves_thenOldSuccessCannotAuthorizeIt() async {
        // given
        let base = TaskDetailVMTests()
        let first = base.conversationTask("first")
        let newest = base.conversationTask("newest", status: "running", parentTaskID: "first", minute: 1)
        let harness = base.makeConversationSUT(openedAs: "first", initialMembers: [first], stubbedMembers: [first, newest],
            chrome: .standalone, statusReadProvider: { id in
                .init(revision: 1, task: id == "first" ? first : nil)
            })
        harness.sut.didAppear()
        #expect(harness.sut.hasStatusAuthority)
        // when
        harness.membersBox.value = [first, newest]
        harness.tasksSubject.send([first, newest])
        await waitUntil { harness.sut.currentTaskID == "newest" }
        // then
        #expect(harness.sut.isStatusUnavailable && !harness.sut.hasStatusAuthority)
        #expect(harness.sut.stateTreatment?.taskID == "newest")
        #expect(!harness.sut.submitMessage("not authorized by first"))
        harness.sut.didDisappear()
    }

    @Test func givenDetailDisappearsWithRetainedSuccessfulRead_whenCallbackRuns_thenCommandsStayBlocked() {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let task = TaskDetailVMTests().task()
        fixtures.statusReadProvider.value = { _ in .init(revision: 1, task: task) }
        fixtures.detailBox.value = task
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        // when
        fixtures.detailBox.value = nil
        harness.sut.recompute()
        // then
        #expect(harness.sut.task == nil && !harness.sut.hasStatusAuthority)
        #expect(!harness.sut.submitMessage("stale callback"))
        #expect(harness.sut.latestActionTask() == nil)
        harness.sut.didDisappear()
    }

    @Test func givenIndependentApprovalAndPaneData_whenStatusFails_thenControllerAndReadOnlyDataSurvive() async throws {
        // given
        let fixtures = TaskDetailVMTests.Fixtures()
        let approval = StatusIndependentApproval()
        fixtures.callerApprovalBox.value = approval
        var raw = TaskDetailVMTests().task(status: "completed").raw
        raw["caller_approvals"] = .bool(true)
        let task = try #require(TaskInfo(.object(raw)))
        fixtures.detailBox.value = task
        fixtures.snapshotBox.value = task
        let read = TaskDetailVMTests.Box<Bool>(true)
        fixtures.statusReadProvider.value = { _ in .init(revision: 1, task: read.value ? task : nil) }
        let harness = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()
        let controller = try #require(harness.sut.callerApprovalController)
        await waitUntil { !controller.cards.isEmpty }
        await controller.inspect(approval.request)
        let summary = harness.sut.summaryModel
        let changes = harness.sut.changesPresentation
        let request = harness.sut.requestReadState
        // when
        read.value = false
        fixtures.statusReadSubject.send(())
        await waitUntil { harness.sut.isStatusUnavailable }
        await controller.respond("approve")
        // then
        #expect(harness.sut.callerApprovalController === controller)
        #expect(approval.responses == 1)
        #expect(harness.sut.summaryModel.finalAnswer == summary.finalAnswer)
        #expect(harness.sut.summaryModel.editedFiles == summary.editedFiles)
        #expect(harness.sut.summaryModel.editedFilesAvailability == summary.editedFilesAvailability)
        #expect(harness.sut.changesPresentation == changes)
        #expect(harness.sut.requestReadState == request)
        #expect(harness.sut.inspectorModel?.hasSnapshot == true)
        harness.sut.didDisappear()
    }
}

@MainActor
private final class StatusIndependentApproval: CallerApprovalUseCase {
    var responses = 0
    let request = CallerApprovalRequest(raw: [
        "request_id": .string("independent"), "task_id": .string("abc12345"),
        "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(1),
        "generation": .string("generation-1"), "interaction_owner": .string("monitor"),
        "disposition": .string("pending"), "delivery": .string("pending"),
        "execution_outcome": .string("unknown"), "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970),
        "complete": .bool(true), "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("echo test")])])
    ])

    func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
        CallerApprovalPage(requests: [request], total: 1)
    }

    func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }
    func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest {
        responses += 1
        return request
    }

    func supportsMonitorResponseForCallerApprovals() async throws -> Bool { true }
}
