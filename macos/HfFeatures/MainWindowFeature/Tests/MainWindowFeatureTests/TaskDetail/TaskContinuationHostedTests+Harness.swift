import AppKit
import Combine
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

// MARK: - HostedContinuationFixture

@MainActor final class HostedContinuationFixture {
    let fixtures: TaskDetailVMTests.Fixtures
    let vm: TaskDetailVMTests.SUT
    let runner: HostedContinuationCtl
    let pages: HostedContinuationPages
    let owner: TaskContinuationRepositoryImpl
    let runtime: QualificationRuntimeToken
    let members: TaskDetailVMTests.Box<[TaskInfo]>
    let sourceID = "abc12345"
    let statusRevision: TaskDetailVMTests.Box<UInt64>

    init(result: Result<ProcessOutput, ToolError> = .success(HostedContinuationCtl.response(task: "accepted-session"))) {
        let fixtures = TaskDetailVMTests.Fixtures()
        let statusRevision = TaskDetailVMTests.Box<UInt64>(1)
        let pages = HostedContinuationPages()
        let runner = HostedContinuationCtl(result: result)
        let client = CtlClient(executable: "/fixture/harflow-ctl", environment: [:], runner: runner)
        let runtime = QualificationRuntimeToken(client: client)
        let tooling = MockToolEnvironmentRepository()
        given(tooling).ctl().willReturn(.success(client))
        let source = Self.task(status: "running")
        let list = HostedContinuationList(pages: pages, tasks: [source])
        let actions = TaskActionRepositoryImpl(toolEnvironment: tooling, taskListRepository: list, snapshotRepository: NullTaskSnapshotRepository())
        let owner = TaskContinuationRepositoryImpl(tooling: tooling, taskList: list, actions: actions, now: { .now })
        let members = TaskDetailVMTests.Box([source])
        fixtures.continuationOwner.value = owner
        fixtures.continuationRuntime.value = runtime
        fixtures.continuationSupport.value = true
        let capturedMembers = members
        fixtures.conversationMembersProvider.value = { _ in capturedMembers.value }
        fixtures.taskProvider.value = { id in capturedMembers.value.first { $0.taskID == id } }
        fixtures.statusReadProvider.value = { id in
            capturedMembers.value.first { $0.taskID == id }.map { TaskSnapshotReadOutcome(revision: statusRevision.value, task: $0) }
        }
        fixtures.detailBox.value = source
        fixtures.snapshotBox.value = source
        let vm = TaskDetailVMTests().makeSUT(chrome: .standalone, fixtures: fixtures)
        given(vm.useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .failed(.notFound(tool: "fixture changes", searched: []))))
        }
        self.fixtures = fixtures
        self.pages = pages
        self.runner = runner
        self.runtime = runtime
        self.owner = owner
        self.members = members
        self.vm = vm
        self.statusRevision = statusRevision
    }

    func installMember(_ id: String) {
        let useCase = vm.useCase
        let members = members
        given(useCase).detail(.value(id)).willProduce { _ in members.value.first { $0.taskID == id } }
        given(useCase).snapshot(.value(id)).willProduce { _ in members.value.first { $0.taskID == id } }
        given(useCase).refreshSnapshot(.value(id)).willReturn()
        given(useCase).children(of: .value(id)).willReturn([])
        given(useCase).siblings(of: .value(id)).willReturn([])
        given(useCase).activity(for: .value(id)).willReturn(ActivityCounts())
        given(useCase).current(for: .value(id)).willReturn(nil)
        given(useCase).prompt(for: .value(id)).willReturn(nil)
        given(useCase).events(for: .value(id)).willReturn([])
        given(useCase).items(for: .value(id)).willReturn([])
        given(useCase).eventsAvailability(for: .value(id)).willReturn(.available)
        given(useCase).eventsAvailabilityPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).itemsPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).observation(for: .value(id)).willReturn(FeatureObservationFixture.frame(id: id, availability: .available))
        given(useCase).observationPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).recoveredTranscript(for: .value(id)).willReturn(RecoveredTranscriptFrame())
        given(useCase).recoveredTranscriptPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        given(useCase).requestState(for: .value(id)).willReturn(.notRequested)
        given(useCase).requestPublisher(for: .value(id)).willReturn(Empty().eraseToAnyPublisher())
        let lease = MockEventStreamLease()
        given(lease).taskID.willReturn(id)
        given(lease).release().willReturn()
        given(useCase).acquireEventLease(.value(id)).willReturn(lease)
    }

    static func task(id: String = "abc12345", status: String = "failed", predecessor: String? = nil) -> TaskInfo {
        var raw: [String: JSONValue] = ["task_id": .string(id), "backend": .string("claude"),
            "status": .string(status), "live_input": .bool(true), "repo_path": .string("/fixture/repository"),
            "session_id": .string("fixture-session"), "resume_command": .string("fixture resume " + id),
            "supervision": .object(["owner_state": .string("alive")])]
        if status != "running" { raw["exit_code"] = .number(1) }
        if let predecessor { raw["continuation_of_task_id"] = .string(predecessor) }
        return TaskInfo(.object(raw))!
    }

    func publishFreshStatusRead() {
        statusRevision.value += 1
        fixtures.statusReadSubject.send(())
    }

    func publish(_ values: [TaskInfo]) {
        statusRevision.value += 1
        members.value = values
        fixtures.detailBox.value = values.last
        fixtures.snapshotBox.value = values.last
        fixtures.tasksSubject.send(values)
        fixtures.snapshotsSubject.send(Dictionary(uniqueKeysWithValues: values.map { ($0.taskID, $0) }))
        fixtures.statusReadSubject.send(())
    }

    func mount(width: CGFloat = 1000, dark: Bool = false) -> RedesignHost {
        let page = RedesignHost(HostedContinuationRoot(sut: vm.sut).preferredColorScheme(dark ? .dark : .light),
                                size: CGSize(width: width, height: 760), appearance: dark ? .dark : .light)
        page.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return page
    }

    func close(_ page: RedesignHost) {
        page.close()
        vm.sut.didDisappear()
    }
}

// MARK: - HostedContinuationRoot

/// Retains one real VM and native feed coordinator across every state transition.
private struct HostedContinuationRoot: View {
    @State var sut: TaskDetailVM
    private let store: TaskPaneStateStore

    init(sut: TaskDetailVM) {
        _sut = State(initialValue: sut)
        let store = TaskPaneStateStore()
        store.setOpenChoice(.closed, for: "abc12345")
        self.store = store
    }

    var body: some View {
        TaskDetailView(sut, chrome: .standalone, paneBinding: .init(store: store, conversationID: "abc12345"), transcriptStyle: .transcript)
    }
}
