import Foundation
import HfRepository
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - TaskDetailViewRepositoryTests + Changes

/// The use case forwards stored-changes reads to the repository with the caller's key and fence, unchanged.
extension TaskDetailViewRepositoryTests {

    @Test func givenAListingRead_whenCalled_thenItForwardsTheKeyAndTheFenceAndReturnsTheRepositoryResult() async throws {
        // given
        let changes = MockTaskChangesRepository()
        let key = TaskChangesKey(taskID: "t1", generation: 7)
        let snapshot = try ChangesJSON.zeroRows()
        given(changes).readListing(key: .any, operationIsCurrent: .any).willProduce { key, fence in
            fence() ? .success(TaskChangesRead(key: key, value: snapshot)) : .failure(TaskChangesReadFailure(key: key, outcome: .superseded))
        }
        let sut = TaskDetailViewRepository(taskChangesRepository: changes)

        // when
        let current = await sut.readChanges(key: key, operationIsCurrent: { true })
        let stale = await sut.readChanges(key: key, operationIsCurrent: { false })

        // then
        #expect(current == .success(TaskChangesRead(key: key, value: snapshot)))
        #expect(stale == .failure(TaskChangesReadFailure(key: key, outcome: .superseded)))
        verify(changes).readListing(key: .value(key), operationIsCurrent: .any).called(2)
    }

    @Test func givenAPatchRead_whenCalled_thenItForwardsTheSelectorToTheRepository() async throws {
        // given
        let changes = MockTaskChangesRepository()
        let key = TaskChangesKey(taskID: "t1", generation: 1)
        let selector = try #require(TaskChangesSelector(repositoryRoot: "/r", scope: .workingTree, pathBytes: Data("a".utf8)))
        given(changes).readPatch(key: .any, selector: .any, operationIsCurrent: .any).willProduce { key, _, _ in
            .failure(TaskChangesReadFailure(key: key, outcome: .clientBound(.deadline)))
        }
        let sut = TaskDetailViewRepository(taskChangesRepository: changes)

        // when
        let result = await sut.readChangesPatch(key: key, selector: selector, operationIsCurrent: { true })

        // then
        #expect(result == .failure(TaskChangesReadFailure(key: key, outcome: .clientBound(.deadline))))
        verify(changes).readPatch(key: .value(key), selector: .value(selector), operationIsCurrent: .any).called(1)
    }
}
