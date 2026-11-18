import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
@Suite struct NewSessionVMRecentsTests {

    private func makeSUT(
        tasks: [TaskInfo] = [], exists: @escaping @Sendable (String) -> Bool = { _ in true }, calls: LockedCalls = LockedCalls()
    ) -> (sut: NewSessionVM, useCase: MockNewSessionUseCase, routing: MockNewSessionRouting) {
        let useCase = MockNewSessionUseCase()
        given(useCase).qualificationSession().willReturn(QualificationFixture.readySession())
        let routing = MockNewSessionRouting()
        given(useCase).backendCatalog.willReturn(.empty)
        given(useCase).tasks.willReturn(tasks)
        given(useCase).existingDirectories(among: .any).willProduce { calls.record($0); return Set($0.filter(exists)) }
        given(useCase).backendCatalogPublisher().willReturn(Empty().eraseToAnyPublisher())
        given(useCase).modelListing(for: .any).willReturn(ModelListing(state: .available))
        given(useCase).agentUsageSnapshot.willReturn(.init())
        given(useCase).agentUsagePublisher().willReturn(Just(.init()).eraseToAnyPublisher())
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        sut.didAppear()
        return (sut, useCase, routing)
    }

    private func task(_ id: String, repo: String, startedAt: String?) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string(id), "repo_path": .string(repo)]
        if let startedAt { object["started_at"] = .string(startedAt) }
        return TaskInfo(.object(object))!
    }

    @Test func givenTasksInManyRepos_whenTheSheetOpens_thenRecentsAreDistinctNewestFirstAndCappedAtFive() async {
        // given — "/a" appears twice; the newer of its two runs decides its place.
        let tasks = [
            task("1", repo: "/a", startedAt: "2026-01-01T10:00:00+00:00"),
            task("2", repo: "/b", startedAt: "2026-01-02T10:00:00+00:00"),
            task("3", repo: "/c", startedAt: "2026-01-03T10:00:00+00:00"),
            task("4", repo: "/a", startedAt: "2026-01-04T10:00:00+00:00"),
            task("5", repo: "/d", startedAt: "2026-01-05T10:00:00+00:00"),
            task("6", repo: "/e", startedAt: "2026-01-06T10:00:00+00:00"),
            task("7", repo: "/f", startedAt: "2026-01-07T10:00:00+00:00"),
            task("8", repo: "", startedAt: "2026-01-08T10:00:00+00:00")
        ]

        // when
        let (sut, _, _) = makeSUT(tasks: tasks)
        await waitUntil { sut.recentRepos.count == 5 }

        // then
        #expect(sut.recentRepos.map(\.path) == ["/f", "/e", "/d", "/a", "/c"])
        #expect(sut.recentRepos.first?.name == "f")
    }

    @Test func givenARecentChip_whenTapped_thenTheRepoFieldIsFilledAndTheChipSelected() async {
        // given
        let (sut, _, _) = makeSUT(tasks: [task("1", repo: "/Users/me/Code/app", startedAt: "2026-01-01T10:00:00+00:00")])
        await waitUntil { !sut.recentRepos.isEmpty }

        // when
        sut.didTapRecentRepo("/Users/me/Code/app")

        // then
        #expect(sut.repo == "/Users/me/Code/app")
        #expect(sut.recentRepos.first?.isSelected == true)
        #expect(sut.recentRepos.first?.name == "app")
    }

    @Test func givenARecentFolderThatNoLongerExists_whenTheSheetOpens_thenItIsDroppedAndAnOlderOneFillsTheSlot() async {
        // given — six repositories, the newest one deleted.
        let tasks = ["/a", "/b", "/c", "/d", "/e", "/f"].enumerated().map { index, path in
            task("\(index)", repo: path, startedAt: "2026-01-0\(index + 1)T10:00:00+00:00")
        }

        // when
        let (sut, _, _) = makeSUT(tasks: tasks, exists: { $0 != "/f" })
        await waitUntil { sut.recentRepos.count == 5 }

        // then
        #expect(sut.recentRepos.map(\.path) == ["/e", "/d", "/c", "/b", "/a"])
    }

    @Test func givenTwentyMissingNewerFoldersThenAnExistingOne_whenTheSheetOpens_thenTheExistingOneStillShows() async {
        // given — the first batch of twenty candidates is all missing, so only the second batch has a hit.
        var tasks = (0 ..< 20).map { task("m\($0)", repo: "/missing\($0)", startedAt: String(format: "2026-02-%02dT10:00:00+00:00", $0 + 1)) }
        tasks.append(task("keep", repo: "/keep", startedAt: "2026-01-01T10:00:00+00:00"))

        // when
        let calls = LockedCalls()
        let (sut, _, _) = makeSUT(tasks: tasks, exists: { $0 == "/keep" }, calls: calls)
        await waitUntil { !sut.recentRepos.isEmpty }

        // then — exactly two checks: the first batch of twenty, then the remainder.
        #expect(sut.recentRepos.map(\.path) == ["/keep"])
        #expect(calls.all.count == 2)
        #expect(calls.all.first?.count == 20)
        #expect(calls.all.last == ["/keep"])
    }

    @Test func givenTheFirstBatchAlreadyHasFiveExistingFolders_whenTheSheetOpens_thenOnlyOneCheckRuns() async {
        // given — twenty-five repositories, all existing.
        let tasks = (0 ..< 25).map { task("t\($0)", repo: "/repo\($0)", startedAt: String(format: "2026-02-%02dT10:00:00+00:00", $0 + 1)) }

        // when
        let calls = LockedCalls()
        let (sut, _, _) = makeSUT(tasks: tasks, calls: calls)
        await waitUntil { sut.recentRepos.count == 5 }

        // then
        #expect(calls.all.count == 1)
        #expect(calls.all.first?.count == 20)
    }

    @Test func givenAFolderDeletedWhileTheSheetIsOpen_whenThePickerOpens_thenItIsDropped() async {
        // given
        let missing = LockedPaths()
        let tasks = [
            task("1", repo: "/a", startedAt: "2026-01-01T10:00:00+00:00"),
            task("2", repo: "/b", startedAt: "2026-01-02T10:00:00+00:00")
        ]
        let (sut, _, _) = makeSUT(tasks: tasks, exists: { !missing.contains($0) })
        await waitUntil { sut.recentRepos.count == 2 }

        // when
        missing.insert("/b")
        sut.didOpenRepositoryPicker()

        // then
        await waitUntil { sut.recentRepos.map(\.path) == ["/a"] }
    }

    @Test func givenARefreshSupersededByAnotherOne_whenTheOlderAnswerArrivesLast_thenItNeverApplies() async {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        useCase.currentTasks = [task("1", repo: "/old", startedAt: "2026-01-01T10:00:00+00:00")]
        sut.didAppear()
        await waitUntil { useCase.requests.count == 1 }
        let supersededTask = sut.recentRepoTask
        useCase.currentTasks = [task("2", repo: "/new", startedAt: "2026-01-02T10:00:00+00:00")]
        sut.didOpenRepositoryPicker()
        await waitUntil { useCase.requests.count == 2 }

        // when — the newer check answers first, then the superseded one.
        useCase.answer(1, ["/new"])
        await waitUntil { sut.recentRepos.map(\.path) == ["/new"] }
        useCase.answer(0, ["/old"])
        await supersededTask?.value

        // then — covers cancelled work never publishing; the generation fence itself is not separately exercised.
        #expect(sut.recentRepos.map(\.path) == ["/new"])
    }

    @Test func givenAPendingCheck_whenTheSheetDisappears_thenNothingIsPublished() async {
        // given
        let useCase = GatedRecentsUseCase()
        let routing = MockNewSessionRouting()
        let sut = NewSessionVM(useCase: useCase, routing: routing)
        useCase.currentTasks = [task("1", repo: "/a", startedAt: "2026-01-01T10:00:00+00:00")]
        sut.didAppear()
        await waitUntil { useCase.requests.count == 1 }

        let pendingTask = sut.recentRepoTask

        // when
        sut.didDisappear()
        useCase.answer(0, ["/a"])
        await pendingTask?.value

        // then — covers cancelled work never publishing; the generation fence itself is not separately exercised.
        #expect(sut.recentRepos.isEmpty)
    }
}
