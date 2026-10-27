import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - StartScreenSemanticPublisherTests

private final class StartScreenTaskSnapshotBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [[TaskInfo]] = []

    func append(_ tasks: [TaskInfo]) { lock.withLock { stored.append(tasks) } }
    var values: [[TaskInfo]] { lock.withLock { stored } }
}

private final class StartScreenErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [ToolError?] = []

    func append(_ error: ToolError?) { lock.withLock { stored.append(error) } }
    var values: [ToolError?] { lock.withLock { stored } }
}

private final class StartScreenHistoryStateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [HistoryLoadingState] = []

    func append(_ state: HistoryLoadingState) { lock.withLock { stored.append(state) } }
    var values: [HistoryLoadingState] { lock.withLock { stored } }
}

@MainActor
@Suite struct StartScreenSemanticPublisherTests {
    private func task(_ status: String, owner: JSONValue = .null, finished: String? = nil,
                      progress: Double) -> TaskInfo {
        var raw: [String: JSONValue] = [
            "task_id": .string("task"), "status": .string(status), "workflow_run_id": owner,
            "duration_seconds": .number(progress)
        ]
        if let finished { raw["finished_at"] = .string(finished) }
        return TaskInfo(.object(raw))!
    }

    private func historyState(catalog: String = "ready", bootstrap: Bool = false, historyIncomplete: Bool = false,
                              authorityIncomplete: Bool = false, countsComplete: Bool = true) -> HistoryLoadingState {
        var value = HistoryLoadingState()
        value.catalogState = CatalogState(raw: ["catalog_state": .object(["status": .string(catalog)])])
        value.bootstrapPending = bootstrap
        value.historyIncomplete = historyIncomplete
        value.authorityIncomplete = authorityIncomplete
        value.countsComplete = countsComplete
        return value
    }

    @Test func givenCurrentValueReplayAndProgressOnlyUpdates_whenObserved_thenOnlySemanticChangesPass() async {
        // given
        let subject = CurrentValueSubject<[TaskInfo], Never>([task("running", progress: 1)])
        let observed = StartScreenTaskSnapshotBox()
        let subscription = StartScreenViewRepository.semanticChanges(subject.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { observed.append($0) }

        // when
        subject.send([task("running", progress: 2)])
        subject.send([task("running", progress: 3)])
        subject.send([task("paused", progress: 3)])
        await waitUntil { observed.values.count == 1 }
        subject.send([task("paused", owner: .string("workflow-run"), progress: 3)])
        await waitUntil { observed.values.count == 2 }
        subject.send([task("paused", owner: .string("workflow-run"), finished: "2026-10-27T10:00:00Z", progress: 3)])
        await waitUntil { observed.values.count == 3 }

        // then
        #expect(observed.values.map { $0[0].raw["status"]?.stringValue } == ["paused", "paused", "paused"])
        #expect(observed.values[1][0].raw["workflow_run_id"] == .string("workflow-run"))
        #expect(observed.values[2][0].raw["finished_at"] == .string("2026-10-27T10:00:00Z"))
        withExtendedLifetime(subscription) {}
    }

    @Test func givenCurrentNilErrorReplayAndRepeatedNil_whenObserved_thenOnlyAChangedErrorPasses() async {
        // given
        let subject = CurrentValueSubject<ToolError?, Never>(nil)
        let observed = StartScreenErrorBox()
        let subscription = StartScreenViewRepository.semanticErrors(subject.eraseToAnyPublisher())
            .sink { observed.append($0) }

        // when
        subject.send(nil)
        let error = ToolError.refused(code: "offline", message: "unavailable")
        subject.send(error)
        await waitUntil { observed.values.count == 1 }
        subject.send(error)

        // then
        #expect(observed.values == [error])
        withExtendedLifetime(subscription) {}
    }

    @Test func givenPaginationChurnAndReadinessTransitions_whenObserved_thenOnlyReadinessTransitionsPass() async {
        // given
        let subject = CurrentValueSubject<HistoryLoadingState, Never>(historyState())
        let observed = StartScreenHistoryStateBox()
        let subscription = StartScreenViewRepository.semanticHistoryState(subject.eraseToAnyPublisher())
            .receive(on: DispatchQueue.main)
            .sink { observed.append($0) }

        // when
        var paginationOnly = historyState()
        paginationOnly.nextCursor = "next"
        paginationOnly.hasMore = true
        paginationOnly.isLoading = true
        subject.send(paginationOnly)

        subject.send(historyState(countsComplete: false))
        await waitUntil { observed.values.count == 1 }
        subject.send(historyState(historyIncomplete: true, countsComplete: false))
        await waitUntil { observed.values.count == 2 }
        subject.send(historyState(historyIncomplete: true, authorityIncomplete: true, countsComplete: false))
        await waitUntil { observed.values.count == 3 }
        subject.send(historyState(catalog: "blocked", historyIncomplete: true, authorityIncomplete: true, countsComplete: false))
        await waitUntil { observed.values.count == 4 }
        subject.send(historyState(catalog: "blocked", bootstrap: true, historyIncomplete: true,
                                  authorityIncomplete: true, countsComplete: false))
        await waitUntil { observed.values.count == 5 }

        // then
        #expect(observed.values.count == 5)
        #expect(observed.values[0].countsComplete == false)
        #expect(observed.values[1].historyIncomplete)
        #expect(observed.values[2].authorityIncomplete)
        #expect(observed.values[3].catalogState.status == .blocked)
        #expect(observed.values[4].bootstrapPending)
        withExtendedLifetime(subscription) {}
    }
}
