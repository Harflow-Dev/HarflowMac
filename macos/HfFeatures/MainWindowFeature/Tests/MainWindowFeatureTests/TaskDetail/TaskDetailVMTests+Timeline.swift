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

/// Monitor piece 8, Codex review round 2, finding 2: the Timeline must be built from the
/// repository's own already-built `items(for:)`/`itemsPublisher(for:)` snapshot (`itemsByMember`),
/// never by rebuilding `Timeline.items(from:)` over the whole raw event history — that rebuild, run
/// for every conversation member on every single publication (including every coalesced delta
/// flush), is exactly what made a running task's timeline O(n²) over its lifetime. The summary
/// model recomputes on every update.
@MainActor
extension TaskDetailVMTests {

    @Test
    func givenItemsForDivergesFromARebuildOfRawEvents_whenBuildingTheTimeline_thenTheRepositorysOwnItemsWin() async {
        // given — deliberately DIVERGENT: `events(for:)` (the raw events) tells one story,
        // `items(for:)` (the Timeline's own source) tells a completely different one. If the VM ever
        // fell back to rebuilding the Timeline via `Timeline.items(from: events(for:))` instead of
        // consuming `items(for:)`/`itemsPublisher(for:)` directly, it would show the events-derived
        // text below — this is the test that would catch that regression.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsBox.value = [TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":0,"kind":"assistant_text","text":"FROM RAW EVENTS"}"#)!]
        harness.itemsOverride.value = Timeline.items(from: [
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":0,"kind":"assistant_text","text":"FROM THE REPOSITORYS OWN ITEMS"}"#)!
        ])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        let texts = harness.sut.timelineModel.rows.compactMap { row -> String? in
            if case .item(let item) = row.kind, case .text(let text, _) = item.body { return text }
            return nil
        }
        #expect(texts == ["FROM THE REPOSITORYS OWN ITEMS"])
        // The raw events are unaffected by the repository's items.
        #expect(harness.sut.rawEvents.count == 1)
        if case .assistantText(let text, _, _) = harness.sut.rawEvents[0].kind {
            #expect(text == "FROM RAW EVENTS")
        } else {
            Issue.record("expected .assistantText")
        }
    }

    @Test
    func givenItemsPublisherEmitsAFreshValue_whenTheSinkRuns_thenTheTimelineUsesThatValueDirectly() async {
        // given — the sink itself (`TaskDetailVM.acquireMemberLease`) must consume the value
        // `itemsPublisher(for:)` delivers, exactly like `ParallelVM.acquireLease` already does —
        // never re-derive it from `events(for:)` inside the sink. `eventsBox` is left holding
        // something else entirely so a fallback to it would be caught here too.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsBox.value = [TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
        + #""seq":0,"kind":"assistant_text","text":"STALE RAW EVENTS"}"#)!]
        // `items(for:)` is explicitly empty at lease-acquisition time, so the ONLY way the Timeline
        // can show anything below is the `itemsSubject.send(...)` a few lines down — never a
        // fallback to `eventsBox`'s content.
        harness.itemsOverride.value = []
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.timelineModel.rows.isEmpty, "no items(for:)/itemsPublisher value has arrived yet")

        // when — the repository publishes a fresh items snapshot, unrelated to `eventsBox`'s content.
        let published = Timeline.items(from: [
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":0,"kind":"assistant_text","text":"PUBLISHED VIA ITEMS PUBLISHER"}"#)!
        ])
        harness.itemsSubject.send(published)

        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        let texts = harness.sut.timelineModel.rows.compactMap { row -> String? in
            if case .item(let item) = row.kind, case .text(let text, _) = item.body { return text }
            return nil
        }
        #expect(texts == ["PUBLISHED VIA ITEMS PUBLISHER"])
    }

    // MARK: - Timeline loading shimmer (Monitor piece 11, Plan review round 1 item 4)

    @Test
    func givenNoRealContentYetAndAvailabilityStillLoading_whenBuiltTheTimeline_thenIsLoadingIsTrue() async {
        // given — no items published yet, and the event stream hasn't reported `.available`/
        // `.unavailable` either.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsAvailabilityBox.value = .loading
        harness.itemsOverride.value = []

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }

        // then
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.timelineModel.isLoading)
        #expect(harness.sut.timelineModel.rows.isEmpty)
    }

    @Test
    func givenRealContentArrives_whenAvailabilityIsStillLoading_thenIsLoadingClears() async {
        // given — once a member has real event content, the shimmer must give way to it even if the
        // stream technically hasn't settled to `.available` yet (a running task's own log is still
        // being tailed).
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsAvailabilityBox.value = .loading
        harness.itemsOverride.value = []
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.timelineModel.isLoading }

        // when
        harness.itemsSubject.send(Timeline.items(from: [
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":0,"kind":"assistant_text","text":"hello"}"#)!
        ]))

        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        #expect(!harness.sut.timelineModel.isLoading)
    }

    @Test
    func givenNoRealContentAndAvailabilityUnavailable_whenBuiltTheTimeline_thenIsLoadingStaysFalse() async {
        // given — Plan review round 1, item 4: never shimmer for `.unavailable`; the honest
        // "event log is empty or was not found" message keeps showing instead.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsAvailabilityBox.value = .unavailable
        harness.itemsOverride.value = []

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }

        // then
        await waitUntil { harness.sut.task != nil }
        #expect(!harness.sut.timelineModel.isLoading)
        #expect(harness.sut.timelineModel.emptyText != nil)
    }

    // MARK: - Summary recomputes without any selection

    @Test
    func givenEventsFactsAreVisible_whenQualifiedEditObservationArrives_thenSummaryUpdates() async {
        // given — captured summary facts live in Events alongside the transcript.
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.summaryModel.editedFiles.isEmpty)

        // when — an edit arrives.
        harness.eventsBox.value = [
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/a.swift"}"#)!,
            TaskEvent(line: #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","#
            + #""seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        harness.itemsSubject.send([])

        // then — the summary model carries the edit.
        await waitUntil { harness.sut.summaryModel.editedFiles == [EditedFile(path: "a.swift", status: .edited)] }
        #expect(harness.sut.summaryModel.editedFiles == [EditedFile(path: "a.swift", status: .edited)])
    }
}
