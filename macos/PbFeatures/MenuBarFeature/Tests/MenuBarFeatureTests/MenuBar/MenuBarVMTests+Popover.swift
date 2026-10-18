import Combine
import Foundation
@testable import MenuBarFeature
import Mockable
import MonitorCore
import PbCommon
import PbTestUtilities
import Testing

extension MenuBarVMTests {

    // MARK: - New session

    @Test func givenNewSessionTapped_whenInvoked_thenItRoutesNewSessionThroughSelectOnly() {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        let routing = harness.routing

        // when
        sut.didTapNewSession()

        // then — routing only; the popover closing is the system's behaviour and is not tested.
        verify(routing).select(.value(.newSession)).called(1)
        verify(routing).openWindow().called(0)
    }

    // MARK: - Header subline

    @Test func givenConnectedAndListed_whenObserved_thenTheSublineIsPolybridgeConnected() async {
        // given
        let harness = makeSUT(connectionLine: "connected · polybridge-ctl")
        let sut = harness.sut
        sut.didAppear()

        // when
        harness.hasListedSubject.send(true)
        harness.listErrorSubject.send(nil)

        // then
        await waitUntil { sut.isConnected }
        #expect(sut.headerSubline == "polybridge connected")
    }

    @Test func givenNotConnected_whenObserved_thenTheSublineIsTheRepositoryConnectionLine() {
        // given
        let harness = makeSUT(connectionLine: "connecting…")

        // then
        #expect(harness.sut.headerSubline == "connecting…")
    }

    // MARK: - Running row model

    @Test func givenARunningTaskInARepo_whenListed_thenTheRowModelCarriesTheRepoName() async {
        // given
        let harness = makeSUT()
        let sut = harness.sut
        sut.didAppear()
        let info = TaskInfo(.object([
            "task_id": .string("abc123"), "backend": .string("claude"), "status": .string("running"),
            "repo_path": .string("/Users/dev/Code/polybridge")
        ]))!

        // when
        harness.tasksSubject.send([info])

        // then
        await waitUntil { sut.runningRows.count == 1 }
        #expect(sut.runningRows.first?.repoName == "polybridge")
    }
}
