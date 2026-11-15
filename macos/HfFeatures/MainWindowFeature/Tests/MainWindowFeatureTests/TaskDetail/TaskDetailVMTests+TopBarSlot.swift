import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - Top bar slot states

/// What a mounted standalone VM writes to the top bar while the task is not known: loading until the listing has been
/// read, not found after, and nothing for the other chromes. Writes are deduplicated on the combined slot value.
extension TaskDetailVMTests {

    /// A standalone harness whose listing publisher already holds `listed`.
    private func seededHarness(listed: Bool, fixtures: Fixtures = Fixtures()) -> SUT {
        let useCase = MockTaskDetailUseCase()
        let routing = MockTaskDetailRouting()
        given(useCase).hasListedPublisher().willReturn(Just(listed).eraseToAnyPublisher())
        let lease = configureStubs(useCase: useCase, routing: routing, taskID: "abc12345", fixtures: fixtures)
        useCase.configurePagingDefaults(includeObservationDefaults: false, includeContinuationDefaults: false,
                                       successorObservation: { _ in false })
        let sut = TaskDetailVM(taskID: "abc12345", useCase: useCase, routing: routing, continuityHistory: TaskContinuityHistoryStore(),
                               chrome: .standalone, scheduler: NullScheduling())
        return SUT(
            sut: sut, useCase: useCase, routing: routing, tasksSubject: fixtures.tasksSubject,
            hasListedSubject: fixtures.hasListedSubject, snapshotsSubject: fixtures.snapshotsSubject,
            busySubject: fixtures.busySubject, outcomesSubject: fixtures.outcomesSubject,
            itemsSubject: fixtures.itemsSubject, eventsAvailabilitySubject: fixtures.eventsAvailabilitySubject,
            lease: lease, detailBox: fixtures.detailBox, snapshotBox: fixtures.snapshotBox,
            eventsBox: fixtures.eventsBox, eventsAvailabilityBox: fixtures.eventsAvailabilityBox,
            ancestorsBox: fixtures.ancestorsBox, refreshSnapshotEffect: fixtures.refreshSnapshotEffect,
            childrenBox: fixtures.childrenBox, itemsOverride: fixtures.itemsOverride,
            recomputeCountEffect: fixtures.recomputeCountEffect, observationBox: fixtures.observationBox,
            observationSubject: fixtures.observationSubject, recoveryBox: fixtures.recoveryBox,
            recoverySubject: fixtures.recoverySubject, requestBox: fixtures.requestBox, requestSubject: fixtures.requestSubject,
            callerApprovalBox: fixtures.callerApprovalBox
        )
    }

    // MARK: Loading and not found

    @Test func givenAnUnreadListingAndUnknownTask_whenTheStandaloneVMAppears_thenItPublishesLoadingWithoutATitle() {
        // given
        let harness = makeSUT(chrome: .standalone)

        // when
        harness.sut.didAppear()

        // then
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .value(harness.sut.topBarTag)).called(1)
        verify(harness.routing).publishTopBarSlot(.value(.notFound), tag: .any).called(0)
        verify(harness.routing).publishTopBar(.any, tag: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenLoadingWasPublished_whenTheListingIsRead_thenItPublishesNotFound() async {
        // given
        let harness = makeSUT(chrome: .standalone)
        harness.sut.didAppear()

        // when
        harness.hasListedSubject.send(true)

        // then
        await verify(harness.routing)
.publishTopBarSlot(.value(.notFound), tag: .value(harness.sut.topBarTag))
            .calledEventually(1, before: .seconds(5))
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenAReadListingThatThePublisherAlreadyHolds_whenTheStandaloneVMAppears_thenItNeverPublishesLoading() {
        // given
        let harness = seededHarness(listed: true)

        // when
        harness.sut.didAppear()

        // then
        #expect(harness.sut.hasListed)
        verify(harness.routing).publishTopBarSlot(.value(.notFound), tag: .any).called(1)
        verify(harness.routing).publishTopBarSlot(.matching { if case .loading = $0 { true } else { false } }, tag: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenAPublisherHoldingAnUnreadListing_whenTheStandaloneVMAppears_thenItPublishesLoading() {
        // given
        let harness = seededHarness(listed: false)

        // when
        harness.sut.didAppear()

        // then
        #expect(!harness.sut.hasListed)
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenAnUnresolvedTaskTheListingStillKnowsByIdentity_whenTheVMAppears_thenLoadingCarriesItsTitle() {
        // given the detail has not resolved, but the first member is known through the task lookup
        let fixtures = Fixtures()
        fixtures.taskProvider.value = { [self] id in id == "abc12345" ? task() : nil }
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)

        // when
        harness.sut.didAppear()

        // then
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: "Task abc12345")), tag: .any).called(1)
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenAnUnresolvedWorkflowExecutionChild_whenTheVMAppears_thenLoadingCarriesTheRequestedTasksTitle() {
        // given the detail has not resolved, and the requested task is a workflow execution child
        let fixtures = Fixtures()
        let child = TaskInfo(.object([
            "task_id": .string("abc12345"), "backend": .string("claude"), "status": .string("running"),
            "workflow_run_id": .string("run-1")
        ]))
        fixtures.taskProvider.value = { id in id == "abc12345" ? child : nil }
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)

        // when
        harness.sut.didAppear()

        // then
        #expect(TaskDetailVM.isWorkflowExecutionChild(child))
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: "Task abc12345")), tag: .any).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenLoadingWithoutATitle_whenTheTitleArrives_thenItRepublishesWithTheTitleOnce() async {
        // given
        let fixtures = Fixtures()
        let harness = makeSUT(chrome: .standalone, fixtures: fixtures)
        harness.sut.didAppear()

        // when
        fixtures.taskProvider.value = { [self] id in id == "abc12345" ? task() : nil }
        fixtures.titlesSubject.send(["abc12345": "Known"])

        // then
        await verify(harness.routing)
.publishTopBarSlot(.value(.loading(title: "Task abc12345")), tag: .any)
            .calledEventually(1, before: .seconds(5))
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(1)
        harness.sut.didDisappear()
    }

    // MARK: Dedup

    @Test func givenAPublishedLoadingSlot_whenRecomputedRepeatedlyWithoutChange_thenNothingIsWrittenAgain() {
        // given
        let harness = makeSUT(chrome: .standalone)
        harness.sut.didAppear()

        // when
        harness.sut.recompute()
        harness.sut.recompute()
        harness.sut.recompute()

        // then
        verify(harness.routing).publishTopBarSlot(.any, tag: .any).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenLoadingThenLoadedThenMissingAgain_whenEachStateChanges_thenEachIsWrittenOnceAndOnlyOnChange() async {
        // given
        let harness = makeSUT(chrome: .standalone)
        let running = task(status: "running")
        harness.sut.didAppear()
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(1)

        // when the task arrives
        harness.detailBox.value = running
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.topBarContent != nil }

        // then the loaded content replaces the loading slot, once
        await verify(harness.routing).publishTopBar(.any, tag: .value(harness.sut.topBarTag)).calledEventually(1, before: .seconds(5))
        harness.sut.recompute()
        verify(harness.routing).publishTopBar(.any, tag: .any).called(1)

        // when the task goes missing again
        harness.detailBox.value = nil
        harness.tasksSubject.send([])

        // then loading is written again, because the last written state was the loaded one, and the entry is not cleared
        await verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).calledEventually(2, before: .seconds(5))
        verify(harness.routing).clearTopBar(tag: .any).called(0)
        harness.sut.recompute()
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(2)
        harness.sut.didDisappear()
    }

    @Test func givenAPublishedLoadingSlot_whenTheViewDisappearsAndReappears_thenTheSameSlotIsWrittenAgain() {
        // given
        let harness = makeSUT(chrome: .standalone)
        harness.sut.didAppear()

        // when
        harness.sut.didDisappear()
        harness.sut.didAppear()

        // then
        verify(harness.routing).publishTopBarSlot(.value(.loading(title: nil)), tag: .any).called(2)
        harness.sut.didDisappear()
    }

    // MARK: Gates

    @Test(arguments: [TaskDetailChrome.group, .embedded])
    func givenANonStandaloneChrome_whenTheTaskIsMissing_thenNoSlotIsPublishedAndTheBarIsNotRequested(chrome: TaskDetailChrome) async {
        // given
        let harness = makeSUT(chrome: chrome)

        // when
        harness.sut.didAppear()
        harness.hasListedSubject.send(true)
        await waitUntil { harness.sut.hasListed }
        harness.sut.recompute()

        // then
        verify(harness.routing).publishTopBarSlot(.any, tag: .any).called(0)
        verify(harness.routing).publishTopBar(.any, tag: .any).called(0)
        verify(harness.routing).activateTopBar(tag: .any).called(0)
        verify(harness.routing).retryTopBarActivation(tag: .any).called(0)
        harness.sut.didDisappear()
    }

    @Test func givenAStandaloneVMThatIsNotMounted_whenTheTaskIsMissing_thenNothingIsPublished() {
        // given
        let harness = makeSUT(chrome: .standalone)

        // when
        harness.sut.recompute()

        // then
        verify(harness.routing).publishTopBarSlot(.any, tag: .any).called(0)
    }

    @Test func givenAMissingTask_whenPublishingTheSlot_thenTheVMAsksToBeShownFirst() {
        // given
        let harness = makeSUT(chrome: .standalone)

        // when
        harness.sut.didAppear()

        // then
        verify(harness.routing).retryTopBarActivation(tag: .value(harness.sut.topBarTag)).called(.atLeastOnce)
        harness.sut.didDisappear()
    }

    // MARK: Loading titles

    @Test func givenAConversation_whenReadingTheLoadingHeaderAndTheLoadingMember_thenBothUseTheFirstMember() {
        // given
        let fixtures = Fixtures()
        let first = conversationTask("a1", minute: 0)
        let second = conversationTask("a2", status: "running", parentTaskID: "a1", minute: 1)
        fixtures.conversationMembersProvider.value = { _ in [first, second] }
        let harness = makeSUT(taskID: "a2", chrome: .standalone, fixtures: fixtures)

        // when
        let header = harness.sut.loadingHeader
        let member = harness.sut.loadingFirstMember

        // then
        #expect(member?.taskID == "a1")
        #expect(header?.title == "Task a1")
    }

    @Test(arguments: [TaskDetailChrome.group, .embedded, .standalone])
    func givenAnyChrome_whenReadingTheLoadingHeader_thenItIsTheListedTasksTitleAndRepo(chrome: TaskDetailChrome) {
        // given
        let harness = makeSUT(chrome: chrome)
        harness.detailBox.value = task(status: "running", repoPath: "/Users/example/Code/Carousell-iOS")

        // when
        let header = harness.sut.loadingHeader

        // then
        #expect(header == TaskLoadingHeader(title: "Task abc12345", repoName: "Carousell-iOS"))
    }

    @Test func givenAWorkflowExecutionChildAndAChain_whenAskedIfItIsAnExecutionChild_thenOnlyTheChildIs() {
        // given
        func info(_ extra: [String: JSONValue]) -> TaskInfo {
            var raw: [String: JSONValue] = ["task_id": .string("t"), "backend": .string("claude"), "status": .string("running")]
            for (key, value) in extra { raw[key] = value }
            return TaskInfo(.object(raw))!
        }

        // when / then
        #expect(TaskDetailVM.isWorkflowExecutionChild(info(["workflow_run_id": .string("run")])))
        #expect(!TaskDetailVM.isWorkflowExecutionChild(info(["workflow_run_id": .string("run"), "workflow_role": .string("orchestrator")])))
        #expect(!TaskDetailVM.isWorkflowExecutionChild(info(["workflow_run_id": .string("run"), "workflow_node_id": .string("n")])))
        #expect(!TaskDetailVM.isWorkflowExecutionChild(info([:])))
        #expect(!TaskDetailVM.isWorkflowExecutionChild(nil))
    }
}
