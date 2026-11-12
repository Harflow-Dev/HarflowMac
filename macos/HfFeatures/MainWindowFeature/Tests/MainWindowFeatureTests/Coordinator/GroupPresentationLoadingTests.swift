import Combine
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - GroupPresentationLoadingTests

/// The group presenter's first-classification state and its group top bar handoff.
@MainActor @Suite struct GroupPresentationLoadingTests {
    /// Records the order of the group top bar writes.
    @MainActor private final class RecordingRouting: ParallelRouting {
        private(set) var events: [String] = []
        private(set) var writers: [ObjectIdentifier] = []
        func selectTask(_: String) {}
        func copyToPasteboard(_: String) -> Bool { false }
        func publishTopBar(_ content: GroupTopBarContent, tag: TaskTopBarHolder.Tag) {
            events.append(content.isLoading ? "publish loading" : "publish loaded")
            writers.append(tag.writer)
        }

        func clearTopBar(tag _: TaskTopBarHolder.Tag) { events.append("clear") }
        func activateTopBar(tag: TaskTopBarHolder.Tag) { events.append("activate"); writers.append(tag.writer) }
        func deactivateTopBar(tag _: TaskTopBarHolder.Tag) { events.append("deactivate") }
        func retryTopBarActivation(tag _: TaskTopBarHolder.Tag) {}
    }

    private func task(_ id: String, session: String, status: String = "completed") -> TaskInfo {
        TaskInfo(.object(["task_id": .string(id), "backend": .string("claude"), "status": .string(status),
                          "session_id": .string(session), "group": .string("group")]))!
    }

    private func makeSUT(_ tasks: CurrentValueSubject<[TaskInfo], Never>, routing: RecordingRouting) -> GroupPresentationVM {
        let useCase = MockGroupPresentationUseCase()
        given(useCase).tasksPublisher().willReturn(tasks.eraseToAnyPublisher())
        return GroupPresentationVM(groupName: "group", useCase: useCase, routing: routing,
                                   makeDetail: { id in TaskDetailVMTests().makeSUT(taskID: id).sut },
                                   makeParallel: { ParallelVMTests().makeSUT(groupName: "group", publishesTopBar: true).sut })
    }

    @Test func givenNoClassificationYet_whenAppearing_thenTheGroupIsNotClassifiedAndTheBarShowsLoading() async {
        // given
        let routing = RecordingRouting()
        let sut = makeSUT(CurrentValueSubject([]), routing: routing)
        defer { sut.didDisappear() }
        #expect(sut.isClassified == false)

        // when
        sut.didAppear()

        // then — loading content is published and activated before anything is classified
        #expect(Array(routing.events.prefix(2)) == ["publish loading", "activate"])
    }

    @Test func givenAnEmptyGroup_whenClassified_thenItIsClassifiedAndTheLoadingContentIsCleared() async throws {
        // given
        let routing = RecordingRouting()
        let sut = makeSUT(CurrentValueSubject([]), routing: routing)
        defer { sut.didDisappear() }

        // when
        sut.didAppear()
        try await waitUntil { sut.isClassified }

        // then
        #expect(sut.detailVM == nil && sut.parallelVM == nil)
        #expect(routing.events.suffix(2) == ["deactivate", "clear"])
    }

    @Test func givenOneConversation_whenClassified_thenTheDetailMountsAndTheLoadingContentIsCleared() async throws {
        // given
        let routing = RecordingRouting()
        let sut = makeSUT(CurrentValueSubject([task("only", session: "s1")]), routing: routing)
        defer { sut.didDisappear() }

        // when
        sut.didAppear()
        try await waitUntil { sut.isClassified && sut.detailVM != nil }

        // then
        #expect(routing.events.contains("clear"))
    }

    @Test func givenSeveralConversations_whenClassified_thenTheParallelVMWritesUnderTheSameIdentityAndNothingIsCleared() async throws {
        // given
        let routing = RecordingRouting()
        let sut = makeSUT(CurrentValueSubject([task("a", session: "s1"), task("b", session: "s2")]), routing: routing)
        defer { sut.didDisappear() }

        // when
        sut.didAppear()
        try await waitUntil { sut.isClassified && sut.parallelVM != nil }

        // then — the loading content is replaced in place by the Parallel VM, never cleared in between
        #expect(routing.events.contains("clear") == false)
        #expect(sut.parallelVM?.topBarTag.writer == routing.writers.first)
    }

    @Test func givenAClassifiedGroup_whenItDisappearsAndReturns_thenItIsUnclassifiedAgain() async throws {
        // given
        let routing = RecordingRouting()
        let sut = makeSUT(CurrentValueSubject([]), routing: routing)
        sut.didAppear()
        try await waitUntil { sut.isClassified }

        // when
        sut.didDisappear()

        // then
        #expect(sut.isClassified == false)
    }
}
