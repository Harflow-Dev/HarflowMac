import Combine
import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import PbCommon
import PbRepository
import PbTestUtilities
import PbUI
import SwiftUI
import Testing

/// Piece 2/3 of the Monitor architecture plan: the Summary tab's "Files the agent edited" section
/// is fed from the live raw event stream the VM already holds — the same `rawEvents` the Raw
/// events tab reads — so it must track every shape that stream can take: the history already on
/// disk when the screen first appears, a later append, a tailer reset, and a disappear/reappear
/// cycle re-seeding it from scratch.
@MainActor
extension TaskDetailVMTests {

    private func editCall(_ callID: String, path: String, seq: Int) -> TaskEvent {
        TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"tool_call","call_id":"\#(callID)","tool":"Edit","#
            + #""category":"edit","input_preview":"{}","path":"\#(path)"}"#)!
    }

    private func okResult(_ callID: String, seq: Int) -> TaskEvent {
        TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"tool_result","call_id":"\#(callID)","ok":true,"output_tail":""}"#)!
    }

    // MARK: - `.summary` tab availability wiring

    @Test func givenEventsAvailabilityPublishes_whenObserved_thenSummaryModelTracksIt() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsAvailabilityBox.value = .loading
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        // Summary only recomputes while shown (Monitor piece 8, Codex review round 2, finding 2).
        harness.sut.didSelectTab(.summary)
        #expect(harness.sut.summaryModel.editedFilesAvailability == .loading)

        // when
        harness.eventsAvailabilitySubject.send(.unavailable)

        // then
        await waitUntil { harness.sut.summaryModel.editedFilesAvailability == .unavailable }
        #expect(harness.sut.summaryModel.editedFilesAvailability == .unavailable)

        // when
        harness.eventsAvailabilitySubject.send(.available)

        // then
        await waitUntil { harness.sut.summaryModel.editedFilesAvailability == .available }
        #expect(harness.sut.summaryModel.editedFilesAvailability == .available)
    }

    // MARK: - EditedFiles fed from the live event stream

    @Test func givenEventsAlreadyOnDiskWhenTheScreenAppears_whenBuilt_thenEditedFilesReflectsTheInitialHistory() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.eventsBox.value = [editCall("c1", path: "/repo/a.swift", seq: 0), okResult("c1", seq: 1)]

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        // Summary only recomputes while shown (Monitor piece 8, Codex review round 2, finding 2).
        await waitUntil { harness.sut.task != nil }
        harness.sut.didSelectTab(.summary)

        // then
        await waitUntil { !harness.sut.summaryModel.editedFiles.isEmpty }
        #expect(harness.sut.summaryModel.editedFiles == [EditedFile(path: "a.swift", status: .edited)])
    }

    @Test func givenANewEventArrivesAfterAppear_whenItemsPublish_thenEditedFilesAppendsIt() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.eventsBox.value = [editCall("c1", path: "/repo/a.swift", seq: 0), okResult("c1", seq: 1)]
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        harness.sut.didSelectTab(.summary)
        await waitUntil { !harness.sut.summaryModel.editedFiles.isEmpty }

        // when — a second call arrives; `itemsPublisher` firing is what makes the VM re-read events
        harness.eventsBox.value += [editCall("c2", path: "/repo/b.swift", seq: 2), okResult("c2", seq: 3)]
        harness.itemsSubject.send([])

        // then
        await waitUntil { harness.sut.summaryModel.editedFiles.count == 2 }
        #expect(Set(harness.sut.summaryModel.editedFiles.map(\.path)) == ["a.swift", "b.swift"])
    }

    @Test func givenTheTailerResets_whenItemsPublish_thenEditedFilesReflectsOnlyTheNewSet() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.eventsBox.value = [editCall("c1", path: "/repo/a.swift", seq: 0), okResult("c1", seq: 1)]
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        harness.sut.didSelectTab(.summary)
        await waitUntil { !harness.sut.summaryModel.editedFiles.isEmpty }

        // when — the underlying log was replaced (a reset); the VM's own `events(for:)` read now
        // returns a wholly different set, exactly as `EventStreamRepositoryImpl` publishes it.
        harness.eventsBox.value = [editCall("c9", path: "/repo/z.swift", seq: 0), okResult("c9", seq: 1)]
        harness.itemsSubject.send([])

        // then
        await waitUntil { harness.sut.summaryModel.editedFiles.map(\.path) == ["z.swift"] }
        #expect(harness.sut.summaryModel.editedFiles == [EditedFile(path: "z.swift", status: .edited)])
    }

    @Test func givenDidDisappearThenDidAppearAgain_whenEventsChangedMeanwhile_thenEditedFilesReflectsTheLatestOnReappear() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.eventsBox.value = [editCall("c1", path: "/repo/a.swift", seq: 0), okResult("c1", seq: 1)]
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        // Summary only recomputes while shown (Monitor piece 8, Codex review round 2, finding 2);
        // `tab` itself survives a disappear/reappear cycle (it is not part of the teardown), so the
        // second `didAppear()` below recomputes Summary without needing to select the tab again.
        harness.sut.didSelectTab(.summary)
        await waitUntil { !harness.sut.summaryModel.editedFiles.isEmpty }

        // when
        harness.sut.didDisappear()
        harness.eventsBox.value = [editCall("c2", path: "/repo/b.swift", seq: 0), okResult("c2", seq: 1)]
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        // then
        await waitUntil { harness.sut.summaryModel.editedFiles.map(\.path) == ["b.swift"] }
        #expect(harness.sut.summaryModel.editedFiles == [EditedFile(path: "b.swift", status: .edited)])
    }
}
