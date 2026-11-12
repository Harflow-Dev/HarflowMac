import Foundation
import HfCommon
import HfCommonTestMock
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import Testing

// MARK: - Group top bar handoff

/// A writer that records the order of its calls.
@MainActor private final class RecordingRouting: ParallelRouting {
    private(set) var events: [String] = []
    func selectTask(_: String) {}
    func copyToPasteboard(_: String) -> Bool { false }
    func publishTopBar(_ content: GroupTopBarContent, tag _: TaskTopBarHolder.Tag) { events.append(content.isLoading ? "publish loading" : "publish loaded") }
    func clearTopBar(tag _: TaskTopBarHolder.Tag) { events.append("clear") }
    func activateTopBar(tag _: TaskTopBarHolder.Tag) { events.append("activate") }
    func deactivateTopBar(tag _: TaskTopBarHolder.Tag) { events.append("deactivate") }
    func retryTopBarActivation(tag _: TaskTopBarHolder.Tag) {}
}

/// Records every value the holder shows for a group, re-arming itself after each change.
@MainActor private final class ShownRecorder {
    private(set) var seen: [GroupTopBarContent?] = []
    private let holder: TaskTopBarHolder
    init(_ holder: TaskTopBarHolder) { self.holder = holder }

    func start() {
        withObservationTracking {
            seen.append(holder.shownGroup)
        } onChange: { [self] in
            Task { @MainActor in start() }
        }
    }
}

@MainActor
extension ParallelVMTests {
    @Test func givenAFreshGroupVM_whenItAppearsAndMembershipResolves_thenItPublishesLoadingBeforeItActivatesAndLoadedAfter() async {
        // given
        let harness = makeSUT()
        let recording = RecordingRouting()
        let sut = ParallelVM(groupName: "g1", useCase: harness.useCase, routing: recording, publishesTopBar: true)
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value[running.taskID] = running

        // when
        sut.didAppear()
        defer { sut.didDisappear() }
        harness.tasksSubject.send([running])
        await waitUntil { recording.events.contains("publish loaded") }

        // then — loading first, then activation, and only then loaded content
        #expect(Array(recording.events.prefix(3)) == ["publish loading", "activate", "publish loaded"], "\(recording.events)")
    }

    @Test func givenTheRealHolder_whenAGroupVMAppearsAndLoads_thenTheShownContentIsNeverNilOrAnEmptyNonLoadingTitle() async {
        // given
        let harness = makeSUT()
        let coordinator = MainWindowCoordinator(parent: MockCoordinator())
        coordinator.selection = .group("g1")
        let sut = ParallelVM(groupName: "g1", useCase: harness.useCase, routing: coordinator, publishesTopBar: true)
        let running = task(id: "t1", status: "running")
        harness.tasksBox.value[running.taskID] = running
        let recorder = ShownRecorder(coordinator.topBar)

        // when
        sut.didAppear()
        defer { sut.didDisappear() }
        recorder.start()
        harness.tasksSubject.send([running])
        await waitUntil { coordinator.topBar.shownGroup?.isLoading == false }
        for _ in 0 ..< 5 { await Task.yield() }

        // then
        let seen = recorder.seen
        #expect(seen.first??.isLoading == true, "the first thing shown is the loading content")
        #expect(seen.allSatisfy { $0 != nil }, "the bar is never empty between loading and loaded: \(seen)")
        #expect(seen.compactMap(\.self).allSatisfy { $0.isLoading || $0.badge != nil }, "a loaded title always has its badge")
        #expect(coordinator.topBar.shownGroup?.badge?.label == "1 running")
    }
}
