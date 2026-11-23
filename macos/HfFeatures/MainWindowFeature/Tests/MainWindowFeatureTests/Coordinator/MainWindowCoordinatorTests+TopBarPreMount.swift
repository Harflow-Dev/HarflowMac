import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - Pre-mount slot

/// The slot state the coordinator derives for a selected task before its view mounts and publishes.
extension MainWindowCoordinatorTests {

    private final class Box<Value>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private final class Install: InstallRepository, @unchecked Sendable {
        var setupState: RuntimeSetupState
        let setupSubject = PassthroughSubject<RuntimeSetupState, Never>()
        init(_ state: RuntimeSetupState) { self.setupState = state }
        func setupStatePublisher() -> AnyPublisher<RuntimeSetupState, Never> { setupSubject.eraseToAnyPublisher() }
        var state: InstallState { .installed }
        func statePublisher() -> AnyPublisher<InstallState, Never> { Just(.installed).eraseToAnyPublisher() }
        var lastCheckMessage: String? { nil }
        func lastCheckMessagePublisher() -> AnyPublisher<String?, Never> { Just(nil).eraseToAnyPublisher() }
        func install() async {}
        func retry() async {}
        func reset() {}
    }

    @MainActor private final class PreMountRig {
        let listing = MockTaskListRepository()
        let tasks: Box<[TaskInfo]>
        let listed: Box<Bool>
        let tasksSubject = PassthroughSubject<[TaskInfo], Never>()
        let listedSubject = PassthroughSubject<Bool, Never>()
        let titles = Box<[String: String]>([:])
        let titlesSubject = PassthroughSubject<[String: String], Never>()
        let install: Install
        let coordinator: MainWindowCoordinator
        var holder: TaskTopBarHolder { coordinator.topBar }

        init(tasks initial: [TaskInfo] = [], listed initialListed: Bool = true, runtime: RuntimeSetupState = .ready) {
            let tasks = Box(initial)
            let listed = Box(initialListed)
            self.tasks = tasks
            self.listed = listed
            given(listing).tasks.willProduce { tasks.value }
            given(listing).hasListed.willProduce { listed.value }
            given(listing).listError.willReturn(nil)
            let titles = titles
            given(listing).title(.any).willProduce { titles.value[$0] ?? "Title \($0)" }
            given(listing).titlesPublisher().willReturn(titlesSubject.eraseToAnyPublisher())
            given(listing).tasksPublisher().willReturn(tasksSubject.eraseToAnyPublisher())
            given(listing).hasListedPublisher().willReturn(listedSubject.eraseToAnyPublisher())
            given(listing).listErrorPublisher().willReturn(Just<ToolError?>(nil).eraseToAnyPublisher())
            self.install = Install(runtime)
            self.coordinator = MainWindowCoordinator(parent: MockCoordinator(), installRepository: install, taskListRepository: listing)
        }
    }

    private func member(_ id: String, parent: String? = nil, extra: [String: JSONValue] = [:]) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
            "session_id": .string("shared"), "started_at": .string("2026-09-30T10:00:00Z"), "repo_path": .string("/repo")
        ]
        if let parent { raw["parent_task_id"] = .string(parent) }
        for (key, value) in extra { raw[key] = value }
        return TaskInfo(.object(raw))!
    }

    // MARK: Cases

    @Test func givenAShownPreMountSlot_whenOnlyTheTitleChanges_thenThePreMountSlotFollowsIt() async {
        // given a known task selected and drawn with the listing's title
        let rig = PreMountRig(tasks: [member("a1")])
        rig.coordinator.selection = .task("a1")
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))

        // when the titles publish a new title and the tasks do not publish again
        rig.titles.value["a1"] = "Renamed"
        rig.titlesSubject.send(["a1": "Renamed"])
        await waitUntil { rig.holder.preMountSlot == .loading(title: "Renamed") }

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Renamed"))
    }

    @Test func givenAKnownTask_whenItIsSelected_thenThePreMountSlotCarriesTheListingTitle() {
        // given
        let rig = PreMountRig(tasks: [member("a1")])

        // when
        rig.coordinator.selection = .task("a1")

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))
    }

    @Test func givenALaterMemberOfAConversation_whenItIsSelected_thenTheTitleIsTheFirstMembers() {
        // given
        let rig = PreMountRig(tasks: [member("a1"), member("a2", parent: "a1")])

        // when
        rig.coordinator.selection = .task("a2")

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))
    }

    @Test func givenAWorkflowExecutionChildInAConversation_whenItIsSelected_thenTheTitleIsItsOwn() {
        // given
        let child = member("a2", parent: "a1", extra: ["workflow_run_id": .string("run-1")])
        let rig = PreMountRig(tasks: [member("a1"), child])

        // when
        rig.coordinator.selection = .task("a2")

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title a2"))
    }

    @Test func givenLogicalWorkflowMembers_whenALaterOneIsSelected_thenItIsNotTreatedAsAnExecutionChild() {
        // given two orchestrator members of one workflow session
        let shared: [String: JSONValue] = ["workflow_run_id": .string("run-1"), "workflow_role": .string("orchestrator")]
        let first = member("o1", extra: shared)
        let second = member("o2", extra: shared.merging(["started_at": .string("2026-09-30T11:00:00Z")]) { _, new in new })
        let rig = PreMountRig(tasks: [first, second])

        // when
        rig.coordinator.selection = .task("o2")

        // then the title is the conversation's first member's, not the selected task's own
        #expect(!TaskDetailVM.isWorkflowExecutionChild(second))
        #expect(rig.holder.preMountSlot == .loading(title: "Title o1"))
    }

    @Test func givenAnUnreadListing_whenAnUnknownTaskIsSelected_thenThePreMountSlotIsLoadingWithoutATitle() {
        // given
        let rig = PreMountRig(listed: false)

        // when
        rig.coordinator.selection = .task("nowhere")

        // then
        #expect(rig.holder.preMountSlot == .loading(title: nil))
    }

    @Test func givenAReadListing_whenAnUnknownTaskIsSelected_thenThereIsNoPreMountSlot() {
        // given
        let rig = PreMountRig(tasks: [member("a1")], listed: true)

        // when
        rig.coordinator.selection = .task("nowhere")

        // then
        #expect(rig.holder.preMountSlot == nil)
    }

    @Test func givenARuntimeThatIsNotReady_whenATaskIsSelected_thenThereIsNoPreMountSlotUntilItBecomesReady() async {
        // given
        let rig = PreMountRig(tasks: [member("a1")], runtime: .checking)

        // when
        rig.coordinator.selection = .task("a1")

        // then
        #expect(rig.holder.preMountSlot == nil)

        // when the runtime qualifies
        rig.install.setupSubject.send(.ready)
        await waitUntil { rig.holder.preMountSlot != nil }

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))
    }

    @Test func givenAReadyRuntime_whenItIsLost_thenThePreMountSlotIsCleared() async {
        // given
        let rig = PreMountRig(tasks: [member("a1")])
        rig.coordinator.selection = .task("a1")
        #expect(rig.holder.preMountSlot != nil)

        // when
        rig.install.setupSubject.send(.checking)
        await waitUntil { rig.holder.preMountSlot == nil }

        // then
        #expect(rig.holder.preMountSlot == nil)
    }

    @Test func givenNonTaskSelections_whenSelected_thenThereIsNoPreMountSlot() {
        // given
        let rig = PreMountRig(tasks: [member("a1")], listed: false)

        // when / then
        for selection: MonitorDestination? in [nil, .newSession, .group("release"), .statistics, .pendingLaunches] {
            rig.coordinator.selection = selection
            #expect(rig.holder.preMountSlot == nil, "\(String(describing: selection))")
        }
    }

    @Test func givenATaskSelection_whenTheSelectionLeavesTasks_thenThePreMountSlotIsCleared() {
        // given
        let rig = PreMountRig(tasks: [member("a1")])
        rig.coordinator.selection = .task("a1")
        #expect(rig.holder.preMountSlot != nil)

        // when
        rig.coordinator.selection = .newSession

        // then
        #expect(rig.holder.preMountSlot == nil)
    }

    @Test func givenTaskAThenTaskB_whenSelectionMoves_thenThePreMountSlotFollowsTheNewTask() {
        // given
        let rig = PreMountRig(tasks: [member("a1"), member("b1")].map(\.self))
        rig.coordinator.selection = .task("a1")

        // when
        rig.coordinator.selection = .task("b1")

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title b1"))
    }

    // MARK: Listing changes

    @Test func givenAnUnreadListing_whenTheTaskArrives_thenTheLoadingSlotGainsItsTitle() async {
        // given
        let rig = PreMountRig(listed: false)
        rig.coordinator.selection = .task("a1")
        #expect(rig.holder.preMountSlot == .loading(title: nil))

        // when
        rig.tasks.value = [member("a1")]
        rig.tasksSubject.send(rig.tasks.value)
        await waitUntil { rig.holder.preMountSlot == .loading(title: "Title a1") }

        // then
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))
    }

    @Test func givenAnUnreadListing_whenItIsReadWithoutTheTask_thenThePreMountSlotBecomesNil() async {
        // given
        let rig = PreMountRig(listed: false)
        rig.coordinator.selection = .task("nowhere")
        #expect(rig.holder.preMountSlot == .loading(title: nil))

        // when
        rig.listed.value = true
        rig.listedSubject.send(true)
        await waitUntil { rig.holder.preMountSlot == nil }

        // then
        #expect(rig.holder.preMountSlot == nil)
    }

    @Test func givenAKnownTask_whenTheListingChangesWithoutAffectingIt_thenTheHolderIsNotWritten() async {
        // given
        let rig = PreMountRig(tasks: [member("a1")])
        rig.coordinator.selection = .task("a1")
        final class Flag: @unchecked Sendable { var fired = false }
        let flag = Flag()
        withObservationTracking { _ = rig.holder.preMountSlot } onChange: { flag.fired = true }

        // when the same listing is published again and the slot is recomputed
        rig.tasksSubject.send(rig.tasks.value)
        rig.coordinator.refreshTaskTopBarPreMount()
        rig.coordinator.refreshTaskTopBarPreMount()
        for _ in 0 ..< 10 { await Task.yield() }

        // then
        #expect(!flag.fired)
        #expect(rig.holder.preMountSlot == .loading(title: "Title a1"))
    }

    @Test func givenAnUnchangedSlot_whenRefreshedAgain_thenTheSlotComputationMatchesTheHolder() {
        // given
        let rig = PreMountRig(tasks: [member("a1")])
        rig.coordinator.selection = .task("a1")

        // when
        rig.coordinator.refreshTaskTopBarPreMount()

        // then
        #expect(rig.coordinator.taskTopBarPreMountSlot() == rig.holder.preMountSlot)
    }
}
