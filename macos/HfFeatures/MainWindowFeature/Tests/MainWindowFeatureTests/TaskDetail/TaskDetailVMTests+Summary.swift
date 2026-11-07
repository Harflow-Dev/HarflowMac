import Combine
import Foundation
import HfCommon
import HfRepository
import HfTestUtilities
import HfUI
@testable import MainWindowFeature
import Mockable
import MonitorCore
import SwiftUI
import Testing

/// Piece 2/3 of the Monitor architecture plan: the summary's "Files edited" section
/// is fed from the event stream the VM already observes, so it must track every shape that stream can take: the history already on
/// disk when the screen first appears, a later append, a tailer reset, and a disappear/reappear
/// cycle re-seeding it from scratch.
@MainActor
extension TaskDetailVMTests {

    private func editCall(_ callID: String, path: String, seq: Int) -> TaskEvent {
        TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":\#(seq),"kind":"tool_call","call_id":"\#(callID)","tool":"Edit","#

            + #""category":"edit","input_preview":"{}","path":"\#(path)"}"#)!
    }

    private func okResult(_ callID: String, seq: Int) -> TaskEvent {
        TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":\#(seq),"kind":"tool_result","call_id":"\#(callID)","ok":true,"output_tail":""}"#)!
    }

    // MARK: - summary availability wiring

    @Test func givenEventsAvailabilityPublishes_whenObserved_thenSummaryModelTracksIt() async {
        // given
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsAvailabilityBox.value = .loading
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.summaryModel.editedFilesAvailability == .loading)

        // when
        harness.eventsAvailabilityBox.value = .unavailable
        harness.eventsAvailabilitySubject.send(.unavailable)

        // then
        await waitUntil { harness.sut.summaryModel.editedFilesAvailability == .unavailable }
        #expect(harness.sut.summaryModel.editedFilesAvailability == .unavailable)

        // when
        harness.eventsAvailabilityBox.value = .available
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
        await waitUntil { harness.sut.task != nil }

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

    // MARK: - Enforcement no longer lives on the summary (Summary item 15)

    @Test func givenEnforcementData_whenTheSummaryIsRebuilt_thenTheModelCarriesNoEnforcementData() async {
        // given — the task still reports enforcement; the Inspector's model owns it now.
        let harness = makeSUT()
        let running = task(status: "running", enforcement: ["os_enforced": .bool(true)])
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }

        // when / then
        await waitUntil { harness.sut.summaryModel.hero != nil }
        #expect(
            Mirror(reflecting: harness.sut.summaryModel).children.contains {
                $0.label?.localizedCaseInsensitiveContains("enforcement") == true
            } == false
        )
    }
}
