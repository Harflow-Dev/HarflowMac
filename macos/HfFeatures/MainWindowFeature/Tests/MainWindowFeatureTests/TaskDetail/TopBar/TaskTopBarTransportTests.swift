//
//  TaskTopBarTransportTests.swift
//  MainWindowFeatureTests
//

import Combine
import Foundation
import HfCommon
import HfCommonTestMock
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskTopBarTransportTests

/// A standalone VM, the real coordinator and its holder: which writer is shown across selections, late writes,
/// reappearance and the listing changing under a mounted view.
@MainActor
@Suite(.serialized) struct TaskTopBarTransportTests {
    private typealias Box = TaskDetailVMTests.Box

    /// Forwards the top bar calls to the coordinator and records what the VM wrote.
    private final class Spy: TaskDetailRouting, @unchecked Sendable {
        let coordinator: MainWindowCoordinator
        private(set) var published: [TaskTopBarContent] = []
        private(set) var cleared = 0
        init(_ coordinator: MainWindowCoordinator) { self.coordinator = coordinator }
        func selectTask(_: String) {}
        func copyToPasteboard(_: String) -> Bool { true }
        func publishTopBar(_ content: TaskTopBarContent, tag: TaskTopBarHolder.Tag) {
            published.append(content)
            coordinator.publishTopBar(content, tag: tag)
        }

        func clearTopBar(tag: TaskTopBarHolder.Tag) { cleared += 1; coordinator.clearTopBar(tag: tag) }
        func activateTopBar(tag: TaskTopBarHolder.Tag) { coordinator.activateTopBar(tag: tag) }
        func deactivateTopBar(tag: TaskTopBarHolder.Tag) { coordinator.deactivateTopBar(tag: tag) }
        func retryTopBarActivation(tag: TaskTopBarHolder.Tag) { coordinator.retryTopBarActivation(tag: tag) }
    }

    @MainActor private struct Writer {
        let sut: TaskDetailVM
        let fixtures: TaskDetailVMTests.Fixtures
        let spy: Spy
        let id: String
        var tag: TaskTopBarHolder.Tag { sut.topBarTag }
    }

    @MainActor private final class Rig {
        let coordinator: MainWindowCoordinator
        let listing = MockTaskListRepository()
        let tasks: Box<[TaskInfo]>
        let listingSubject = PassthroughSubject<[TaskInfo], Never>()
        var holder: TaskTopBarHolder { coordinator.topBar }

        init(tasks: [TaskInfo] = []) {
            let box = Box(tasks)
            self.tasks = box
            given(listing).hasListed.willReturn(true)
            given(listing).listError.willReturn(nil)
            given(listing).tasks.willProduce { box.value }
            given(listing).tasksPublisher().willReturn(listingSubject.eraseToAnyPublisher())
            given(listing).hasListedPublisher().willReturn(Just(true).eraseToAnyPublisher())
            given(listing).listErrorPublisher().willReturn(Just<ToolError?>(nil).eraseToAnyPublisher())
            self.coordinator = MainWindowCoordinator(parent: MockCoordinator(), taskListRepository: listing)
        }

        func writer(_ id: String, conversation: String? = nil, chrome: TaskDetailChrome = .standalone, status: String = "running",
                    snapshot: TaskInfo? = nil) -> Writer {
            let base = TaskDetailVMTests()
            let useCase = MockTaskDetailUseCase()
            let fixtures = TaskDetailVMTests.Fixtures()
            base.configureStubs(useCase: useCase, routing: MockTaskDetailRouting(), taskID: id, fixtures: fixtures)
            useCase.configurePagingDefaults(includeObservationDefaults: false)
            given(useCase).readChanges(key: .any, operationIsCurrent: .any).willProduce { key, _ in
                .failure(TaskChangesReadFailure(key: key, outcome: .superseded))
            }
            fixtures.detailBox.value = base.task(id: id, status: status)
            fixtures.snapshotBox.value = snapshot
            let spy = Spy(coordinator)
            let sut = TaskDetailVM(taskID: id, useCase: useCase, routing: spy, continuityHistory: TaskContinuityHistoryStore(),
                                   chrome: chrome, scheduler: NullScheduling(), topBarConversationID: conversation ?? id)
            return Writer(sut: sut, fixtures: fixtures, spy: spy, id: id)
        }

        func appear(_ writer: Writer) async {
            writer.sut.didAppear()
            if let task = writer.fixtures.detailBox.value { writer.fixtures.tasksSubject.send([task]) }
            await waitUntil { writer.sut.task != nil && writer.sut.inspectorModel != nil }
        }

        /// Changes the writer's status and waits for it to be written (or, off the standalone mount, for the recompute).
        func setStatus(_ writer: Writer, _ status: String, label: String) async {
            let base = TaskDetailVMTests()
            writer.fixtures.detailBox.value = base.task(id: writer.id, status: status)
            writer.fixtures.tasksSubject.send([writer.fixtures.detailBox.value!])
            await waitUntil { writer.sut.task?.status.label == label }
            await waitUntil { writer.sut.lastPublishedTopBar?.badge.label == label }
        }
    }

    private func conversation() -> [TaskInfo] {
        func make(_ id: String, parent: String?) -> TaskInfo {
            var raw: [String: JSONValue] = [
                "task_id": .string(id), "backend": .string("claude"), "status": .string("completed"),
                "session_id": .string("shared"), "started_at": .string("2026-09-30T10:00:00Z")
            ]
            if let parent { raw["parent_task_id"] = .string(parent) }
            return TaskInfo(.object(raw))!
        }
        return [make("a1", parent: nil), make("a2", parent: "a1")]
    }

    // MARK: - Coordinator selection

    @Test func givenTaskSelections_whenSelectionChanges_thenTheShownConversationFollowsAndNonTasksClearIt() {
        // given
        let rig = Rig()

        // when / then
        rig.coordinator.selection = .task("a")
        #expect(rig.holder.shownConversation == "a")
        rig.coordinator.selection = .newSession
        #expect(rig.holder.shownConversation == nil)
        rig.coordinator.selection = .task("b")
        #expect(rig.holder.shownConversation == "b")
        rig.coordinator.selection = nil
        #expect(rig.holder.shownConversation == nil)
    }

    @Test func givenAnUnknownId_whenNormalised_thenItIsItself() {
        // given
        let rig = Rig(tasks: conversation())

        // when / then
        #expect(rig.coordinator.normalisedConversationID(for: "nowhere") == "nowhere")
    }

    @Test func givenAConversation_whenAnyMemberIsNormalised_thenItIsTheFirstMember() {
        // given
        let rig = Rig(tasks: conversation())

        // when / then
        #expect(rig.coordinator.normalisedConversationID(for: "a1") == "a1")
        #expect(rig.coordinator.normalisedConversationID(for: "a2") == "a1")
    }

    @Test func givenAnActiveWriter_whenAnotherMemberOfTheSameConversationIsSelected_thenTheWriterStaysActive() async {
        // given
        let rig = Rig(tasks: conversation())
        rig.coordinator.selection = .task("a1")
        let writer = rig.writer("a1")
        await rig.appear(writer)

        // when
        rig.coordinator.selection = .task("a2")

        // then
        #expect(rig.holder.activeTag == writer.tag)
        #expect(rig.holder.shown?.title == "Task a1")
        writer.sut.didDisappear()
    }

    // MARK: - Publishing

    @Test func givenAStandaloneVM_whenItAppears_thenItPublishesAndBecomesTheShownWriter() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")

        // when
        await rig.appear(writer)

        // then
        #expect(rig.holder.shown?.title == "Task a")
        #expect(rig.holder.shown?.badge.label == "Running")
        #expect(rig.holder.activeTag == writer.tag)
        #expect(!writer.spy.published.isEmpty)
        writer.sut.didDisappear()
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenGroupOrEmbedded_whenTheVMAppears_thenItNeverPublishesOrActivates(chrome: TaskDetailChrome) async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a", chrome: chrome)

        // when
        await rig.appear(writer)
        writer.sut.setPaneOpen(true)
        writer.sut.didDisappear()

        // then
        #expect(writer.spy.published.isEmpty)
        #expect(writer.spy.cleared == 0)
        #expect(rig.holder.shown == nil)
        #expect(rig.holder.activeTag == nil)
    }

    @Test func givenAShownWriter_whenARecomputeProducesTheSameContent_thenNothingIsWritten() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")
        await rig.appear(writer)
        let baseline = writer.spy.published.count

        // when metadata that is not drawn changes, and recomputes repeat
        var raw = writer.fixtures.detailBox.value!.raw
        raw["summary"] = .string("More activity")
        raw["num_turns"] = .number(4)
        writer.fixtures.detailBox.value = TaskInfo(.object(raw))
        writer.fixtures.tasksSubject.send([writer.fixtures.detailBox.value!])
        await waitUntil { writer.sut.task?.summary == "More activity" }
        writer.sut.recompute()
        writer.sut.recompute()

        // then
        #expect(writer.spy.published.count == baseline)
        writer.sut.didDisappear()
    }

    // MARK: - Late writes

    @Test func givenAThenB_whenALateWriteFromAArrives_thenBStaysShown() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let outgoing = rig.writer("a")
        await rig.appear(outgoing)
        rig.coordinator.selection = .task("b")
        let incoming = rig.writer("b")
        await rig.appear(incoming)
        #expect(rig.holder.shown?.title == "Task b")

        // when the outgoing view is still mounted and writes
        await rig.setStatus(outgoing, "completed", label: "Done")
        outgoing.sut.didDisappear()

        // then
        #expect(rig.holder.shown?.title == "Task b")
        #expect(rig.holder.shown?.badge.label == "Running")
        #expect(rig.holder.activeTag == incoming.tag)
        incoming.sut.didDisappear()
    }

    @Test func givenAThenBThenA_whenTheFirstAWritesAndClearsLate_thenTheSecondAStaysShown() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let first = rig.writer("a")
        await rig.appear(first)
        rig.coordinator.selection = .task("b")
        let incoming = rig.writer("b")
        await rig.appear(incoming)
        rig.coordinator.selection = .task("a")
        let second = rig.writer("a")
        await rig.appear(second)
        #expect(rig.holder.activeTag == second.tag)
        #expect(first.tag != second.tag)

        // when the stale generation publishes different content, then clears and deactivates
        await rig.setStatus(first, "completed", label: "Done")
        #expect(rig.holder.shown?.badge.label == "Running")
        first.sut.didDisappear()
        incoming.sut.didDisappear()

        // then
        #expect(rig.holder.activeTag == second.tag)
        #expect(rig.holder.shown?.title == "Task a")
        #expect(rig.holder.shown?.badge.label == "Running")
        second.sut.didDisappear()
    }

    @Test func givenANonTaskSelection_whenALateWriteArrives_thenNothingIsShown() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let outgoing = rig.writer("a")
        await rig.appear(outgoing)

        // when
        rig.coordinator.selection = .newSession
        #expect(rig.holder.shown == nil)
        await rig.setStatus(outgoing, "completed", label: "Done")

        // then the principal falls back to the context title
        #expect(rig.holder.shown == nil)
        #expect(rig.holder.shownConversation == nil)
        #expect(rig.holder.activeTag == nil)
        outgoing.sut.didDisappear()
    }

    @Test func givenTheNewAIsActive_whenTheOldAMountedStillRecomputes_thenItsRetryNeverReplacesTheActiveTag() async {
        // given A, then B, then a second A that is active while the first A is still mounted
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let first = rig.writer("a")
        await rig.appear(first)
        rig.coordinator.selection = .task("b")
        let incoming = rig.writer("b")
        await rig.appear(incoming)
        rig.coordinator.selection = .task("a")
        let second = rig.writer("a")
        await rig.appear(second)
        #expect(rig.holder.activeTag == second.tag)

        // when the old one recomputes with different content, which retries its activation
        await rig.setStatus(first, "completed", label: "Done")
        first.sut.recompute()

        // then
        #expect(rig.holder.activeTag == second.tag)
        #expect(rig.holder.shown?.badge.label == "Running")
        first.sut.didDisappear()
        incoming.sut.didDisappear()
        second.sut.didDisappear()
    }

    // MARK: - Lifecycle

    @Test func givenAShownWriter_whenItDisappearsAndReappearsWithIdenticalContent_thenItPublishesAgain() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")
        await rig.appear(writer)
        let original = rig.holder.shown
        let baseline = writer.spy.published.count

        // when
        writer.sut.didDisappear()
        #expect(rig.holder.shown == nil)
        await rig.appear(writer)

        // then
        await waitUntil { rig.holder.shown != nil }
        #expect(rig.holder.shown == original)
        #expect(writer.spy.published.count > baseline)
        writer.sut.didDisappear()
    }

    @Test func givenAShownWriter_whenTheTaskGoesMissingAndReturnsIdentical_thenItClearsThenRepublishes() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")
        await rig.appear(writer)
        let task = writer.fixtures.detailBox.value!
        let original = rig.holder.shown
        let baseline = writer.spy.published.count

        // when the task goes missing
        writer.fixtures.detailBox.value = nil
        writer.fixtures.tasksSubject.send([])
        await waitUntil { writer.sut.task == nil }

        // then
        #expect(rig.holder.shown == nil)
        #expect(writer.sut.lastPublishedTopBar == nil)

        // when the identical task is restored while still mounted
        writer.fixtures.detailBox.value = task
        writer.fixtures.tasksSubject.send([task])
        await waitUntil { rig.holder.shown != nil }

        // then
        #expect(rig.holder.shown == original)
        #expect(writer.spy.published.count > baseline)
        writer.sut.didDisappear()
    }

    @Test func givenAShownWriter_whenAMismatchedTagClears_thenItIsIgnored() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")
        await rig.appear(writer)

        // when
        let other = TopBarFixtures.tag(TopBarFixtures.Writer(), "a")
        rig.coordinator.clearTopBar(tag: other)
        rig.coordinator.deactivateTopBar(tag: other)

        // then
        #expect(rig.holder.shown?.title == "Task a")
        writer.sut.didDisappear()
    }

    @Test func givenARefusedActivation_whenTheSelectionCatchesUpAndTheVMPublishes_thenItIsShown() async {
        // given a VM that appeared before the selection named its conversation
        let rig = Rig()
        let writer = rig.writer("a")
        await rig.appear(writer)
        #expect(rig.holder.shown == nil)

        // when
        rig.coordinator.selection = .task("a")
        await rig.setStatus(writer, "completed", label: "Done")

        // then the publish asked again and was accepted
        await waitUntil { rig.holder.shown != nil }
        #expect(rig.holder.activeTag == writer.tag)
        #expect(rig.holder.shown?.badge.label == "Done")
        writer.sut.didDisappear()
    }

    // MARK: - Pane toggle

    @Test func givenANoticesChip_whenThePaneTogglesOpenThenClosed_thenMetaDropsThenReturnsWithoutATaskRefresh() async {
        // given a snapshot with a notice
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let base = TaskDetailVMTests()
        var raw = base.task(id: "a").raw
        raw["notices"] = .array([.string("A notice")])
        let writer = rig.writer("a", snapshot: TaskInfo(.object(raw)))
        let recomputes = Box(0)
        writer.fixtures.recomputeCountEffect.value = { recomputes.value += 1 }
        await rig.appear(writer)
        await waitUntil { rig.holder.shown?.noticeCount == 1 }
        await waitUntil(timeout: 0.2) { false }
        let original = rig.holder.shown
        let refreshes = recomputes.value
        let writes = writer.spy.published.count
        #expect(original?.showsMeta(isNarrow: false) == true)

        // when
        writer.sut.setPaneOpen(true)

        // then
        #expect(rig.holder.shown?.paneOpen == true)
        #expect(rig.holder.shown?.showsMeta(isNarrow: false) == false)
        #expect(writer.spy.published.count == writes + 1)

        // when the same state is reported again
        writer.sut.setPaneOpen(true)
        #expect(writer.spy.published.count == writes + 1)

        // when
        writer.sut.setPaneOpen(false)

        // then
        #expect(rig.holder.shown == original)
        #expect(rig.holder.shown?.showsMeta(isNarrow: false) == true)
        #expect(recomputes.value == refreshes)
        writer.sut.didDisappear()
    }

    @Test func givenAnOpenPane_whenTheVMDisappearsAndReappears_thenThePaneStartsClosed() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a")
        let writer = rig.writer("a")
        await rig.appear(writer)
        writer.sut.setPaneOpen(true)
        #expect(rig.holder.shown?.paneOpen == true)

        // when
        writer.sut.didDisappear()
        await rig.appear(writer)
        await waitUntil { rig.holder.shown != nil }

        // then
        #expect(rig.holder.shown?.paneOpen == false)
        writer.sut.didDisappear()
    }

    // MARK: - Listing changes

    @Test func givenANonFirstMemberSelectedBeforeTheListingLoads_whenTheListingLoadsBeforeTheViewMounts_thenTheTitleShows() async {
        // given selection happens while the listing is empty
        let rig = Rig()
        rig.coordinator.selection = .task("a2")
        #expect(rig.holder.shownConversation == "a2")

        // when the listing arrives without the publisher having told the coordinator yet
        rig.tasks.value = conversation()
        #expect(rig.coordinator.normalisedConversationID(for: "a2") == "a1")
        let writer = rig.writer("a2", conversation: "a1")
        await rig.appear(writer)

        // then activation recomputed the stale shown conversation
        #expect(rig.holder.shownConversation == "a1")
        #expect(rig.holder.shown?.title == "Task a2")
        writer.sut.didDisappear()
    }

    @Test func givenANonFirstMemberSelectedBeforeTheListingLoads_whenTheListingPublishesWithNoMountedView_thenTheShownConversationCorrects() async {
        // given
        let rig = Rig()
        rig.coordinator.selection = .task("a2")

        // when
        rig.tasks.value = conversation()
        rig.listingSubject.send(conversation())
        await waitUntil { rig.holder.shownConversation == "a1" }

        // then
        #expect(rig.holder.shownConversation == "a1")
    }

    @Test func givenAMountedViewUnderTheFirstMember_whenRetentionShiftsTheFirstMemberWithoutASelectionChange_thenTheTitleStays() async {
        // given a mounted view keyed to a1
        let rig = Rig(tasks: conversation())
        rig.coordinator.selection = .task("a2")
        #expect(rig.holder.shownConversation == "a1")
        let writer = rig.writer("a2", conversation: "a1")
        await rig.appear(writer)
        #expect(rig.holder.shown?.title == "Task a2")

        // when the first member is pruned from the listing
        rig.tasks.value = [conversation()[1]]
        rig.listingSubject.send(rig.tasks.value)
        await waitUntil(timeout: 0.3) { rig.holder.shownConversation != "a1" }

        // then the mounted view keeps its title until a selection or rebuild re-keys it
        #expect(rig.holder.shownConversation == "a1")
        #expect(rig.holder.shown?.title == "Task a2")
        #expect(rig.holder.activeTag == writer.tag)
        writer.sut.didDisappear()
    }

    @Test func givenNoMountedView_whenRetentionShiftsTheFirstMember_thenTheShownConversationFollows() async {
        // given
        let rig = Rig(tasks: conversation())
        rig.coordinator.selection = .task("a2")
        #expect(rig.holder.shownConversation == "a1")

        // when
        rig.tasks.value = [conversation()[1]]
        rig.listingSubject.send(rig.tasks.value)
        await waitUntil { rig.holder.shownConversation == "a2" }

        // then
        #expect(rig.holder.shownConversation == "a2")
    }
}
