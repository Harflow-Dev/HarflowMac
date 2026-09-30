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

/// Monitor piece 8, Codex review round 2, finding 2: the Timeline must be built from the
/// repository's own already-built `items(for:)`/`itemsPublisher(for:)` snapshot (`itemsByMember`),
/// never by rebuilding `Timeline.items(from:)` over the whole raw event history — that rebuild, run
/// for every conversation member on every single publication (including every coalesced delta
/// flush), is exactly what made a running task's Timeline tab O(n²) over its lifetime. Summary, kept
/// on raw events for "Files the agent edited", is gated so it only recomputes while its own tab is
/// actually shown.
@MainActor
extension TaskDetailVMTests {

    @Test
    func givenItemsForDivergesFromARebuildOfRawEvents_whenBuildingTheTimeline_thenTheRepositorysOwnItemsWin() async {
        // given — deliberately DIVERGENT: `events(for:)` (Raw Events/Summary) tells one story,
        // `items(for:)` (the Timeline's own source) tells a completely different one. If the VM ever
        // fell back to rebuilding the Timeline via `Timeline.items(from: events(for:))` instead of
        // consuming `items(for:)`/`itemsPublisher(for:)` directly, it would show the events-derived
        // text below — this is the test that would catch that regression.
        let harness = makeSUT()
        let running = task(status: "running")
        harness.detailBox.value = running
        harness.eventsBox.value = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"assistant_text","text":"FROM RAW EVENTS"}"#)!]
        harness.itemsOverride.value = Timeline.items(from: [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"assistant_text","text":"FROM THE REPOSITORYS OWN ITEMS"}"#)!
        ])

        // when
        harness.sut.didAppear()
        harness.tasksSubject.send([running])

        // then
        await waitUntil { !harness.sut.timelineModel.rows.isEmpty }
        let texts = harness.sut.timelineModel.rows.compactMap { row -> String? in
            if case .item(let item) = row.kind, case .text(let text, _) = item.body { return text }
            return nil
        }
        #expect(texts == ["FROM THE REPOSITORYS OWN ITEMS"])
        // Raw Events, unaffected — it still reads `events(for:)` directly, never `items(for:)`.
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
        harness.eventsBox.value = [TaskEvent(line: #"{"v":1,"seq":0,"kind":"assistant_text","text":"STALE RAW EVENTS"}"#)!]
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
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"assistant_text","text":"PUBLISHED VIA ITEMS PUBLISHER"}"#)!
        ])
        harness.itemsSubject.send(published)

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
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"assistant_text","text":"hello"}"#)!
        ]))

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

        // then
        await waitUntil { harness.sut.task != nil }
        #expect(!harness.sut.timelineModel.isLoading)
        #expect(harness.sut.timelineModel.emptyText != nil)
    }

    // MARK: - Summary recomputes only while shown (Monitor piece 8, Codex review round 2, finding 2)

    @Test
    func givenTheSummaryTabIsNotShown_whenEditableEventsArrive_thenSummaryModelStaysAtItsPriorState() async {
        // given — the simpler of finding 2's two options was chosen (recompute Summary only while
        // its own tab is shown, over gating on "did a non-delta event arrive"); this is the negative
        // case that actually distinguishes it from the old always-recompute behavior.
        let harness = makeSUT()
        let running = task(status: "running", repoPath: "/repo")
        harness.detailBox.value = running
        harness.sut.didAppear()
        harness.tasksSubject.send([running])
        await waitUntil { harness.sut.task != nil }
        #expect(harness.sut.tab == .activity, "the default tab — Summary has never been shown")
        #expect(harness.sut.summaryModel.editedFiles.isEmpty)

        // when — an edit arrives while the Timeline tab (not Summary) is showing.
        harness.eventsBox.value = [
            TaskEvent(line: #"{"v":1,"seq":0,"kind":"tool_call","call_id":"c1","tool":"Edit","category":"edit","input_preview":"","path":"/repo/a.swift"}"#)!,
            TaskEvent(line: #"{"v":1,"seq":1,"kind":"tool_result","call_id":"c1","ok":true,"output_tail":""}"#)!
        ]
        harness.itemsSubject.send([])
        try? await Task.sleep(for: .milliseconds(100))

        // then — Summary was never asked to look, so it still shows nothing.
        #expect(harness.sut.summaryModel.editedFiles.isEmpty)

        // when — switching TO Summary recomputes it immediately from the data already gathered.
        harness.sut.didSelectTab(.summary)

        // then
        #expect(harness.sut.summaryModel.editedFiles == [EditedFile(path: "a.swift", status: .edited)])
    }
}
