import Foundation
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Observation
import PbTestUtilities
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test func givenEqualTimelineInputs_whenRecomputed_thenNoNewPresentationRevision() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "completed")
        harness.sut.didAppear()
        harness.tasksSubject.send([harness.detailBox.value!])
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }
        let revision = harness.sut.timelineRevision
        let presentation = harness.sut.appliedTimelinePresentation
        // when
        harness.sut.recompute()
        // then
        #expect(harness.sut.timelineRevision == revision)
        #expect(harness.sut.timelineWorker == nil)
        #expect(harness.sut.appliedTimelinePresentation == presentation)
        harness.sut.didDisappear()
    }

    @Test func givenSourceRejectsOlderPage_whenHistoryPresentationWasStale_thenRequestAndLoadingClear() async {
        let member = conversationTask("current", minute: 0)
        let harness = makeConversationSUT(openedAs: "current", initialMembers: [member],
            eventHistory: { _ in EventHistoryState(hasMore: true) })
        given(harness.useCase).loadMoreEvents(.value("current")).willReturn(false)
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil && !harness.sut.conversationLoading }
        let counter = TimelineObservationCounter()
        withObservationTracking { _ = harness.sut.timelineModel } onChange: {
            Task { @MainActor in counter.writes += 1 }
        }
        let accepted = harness.sut.loadMoreConversationActivity()
        await waitUntil { harness.sut.timelineWorker == nil && !harness.sut.timelineModel.history.isLoading }
        for _ in 0 ..< 10 { await Task.yield() }
        #expect(counter.writes == 0)
        #expect(!accepted)
        #expect(!harness.sut.olderActivityRequest)
        #expect(!harness.sut.timelineModel.history.isLoading)
    }

    @Test func givenTimelineInput_whenBuiltDetached_thenRunsOffMainAndRetainsCompleteValues() async throws {
        // given
        let task = task(status: "running")
        let event = try #require(TaskEvent(line: #"{"v":1,"seq":1,"kind":"assistant_text","text":"Synthetic activity"}"#))
        let input = TaskDetailTimelineInput(task: task,
            members: [ParallelMemberInput(task: task, items: Timeline.items(from: [event]), prompt: nil, availability: .available)],
            children: [], start: task.startedAt, isBuilder: false, events: [event], snapshot: task,
            history: EventHistoryState(hasMore: true, error: "Synthetic retry", generation: 3))
        // when
        let result = try await Task.detached {
            let background = detailBackgroundThread()
            return (background, try TaskDetailTimelineBuilder.build(input))
        }
.value
        // then
        #expect(result.0)
        #expect(result.1.stepCount == 1)
        #expect(result.1.history == input.history)
        #expect(result.1.activityRows.count == 1)
    }

    @Test func givenEmptyOlderPageWithCursorProgress_whenCompleted_thenRevisionSignalsAndDuplicateRequestIsSuppressed() async {
        // given
        let member = conversationTask("current")
        let state = Box(EventHistoryState(hasMore: true, generation: 1))
        let harness = makeConversationSUT(openedAs: "current", initialMembers: [member], eventHistory: { _ in state.value })
        given(harness.useCase).loadMoreEvents(.value("current")).willProduce { _ in
            state.value = EventHistoryState(hasMore: true, generation: 2)
            return true
        }
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil && !harness.sut.conversationLoading }
        let revision = harness.sut.activityPaginationRevision
        // when
        let accepted = harness.sut.timelineModel.onLoadMore?()
        #expect(accepted == true)
        #expect(harness.sut.timelineModel.history.isLoading)
        harness.sut.timelineModel.onLoadMore?()
        await waitUntil { !harness.sut.olderActivityRequest && harness.sut.timelineWorker == nil }
        // then
        #expect(harness.sut.activityPaginationRevision == revision + 1)
        #expect(harness.sut.timelineModel.paginationRevision == revision + 1)
        verify(harness.useCase).loadMoreEvents(.value("current")).called(1)
        harness.sut.didDisappear()
    }

    @Test func givenPendingTimelineBuild_whenDisappearing_thenResultCannotRepublishAndReopenRebuilds() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task(status: "completed")
        harness.sut.didAppear()
        // when
        harness.sut.didDisappear()
        await waitUntil { harness.sut.timelineWorker == nil }
        // then
        #expect(harness.sut.appliedTimelinePresentation == nil)
        #expect(harness.sut.latestTimelineInput == nil)
        // when
        harness.sut.didAppear()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.appliedTimelinePresentation != nil }
        // then
        #expect(harness.sut.appliedTimelinePresentation != nil)
        harness.sut.didDisappear()
    }
}

private nonisolated func detailBackgroundThread() -> Bool { !Thread.isMainThread }

@MainActor
extension TaskDetailVMTests {
    @Test func givenOlderWorkerFinishesLate_whenInputChanges_thenOnlyNewestPresentationApplies() async {
        // given
        let harness = makeSUT()
        let gate = DetailBuildGate()
        harness.detailBox.value = task(status: "running")
        harness.sut.timelineBuild = { input in
            let value = try? TaskDetailTimelineBuilder.build(input)
            await gate.pauseFirst()
            return value
        }
        harness.sut.didAppear()
        await gate.waitUntilEntered()
        // when — deliberately ignore worker cancellation and return the older value late.
        harness.detailBox.value = task(status: "completed")
        harness.sut.recompute()
        await gate.release()
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.appliedTimelinePresentation != nil }
        // then
        #expect(harness.sut.latestTimelineInput?.task.status == .completed)
        #expect(harness.sut.appliedTimelinePresentation?.emptyText == nil)
        #expect(harness.sut.appliedTimelinePresentation?.noToolCallsText == "No tool calls recorded")
        harness.sut.didDisappear()
    }
}

private actor DetailBuildGate {
    private var entered = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?

    func pauseFirst() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation in
            blocked = continuation
            waiting?.resume()
            waiting = nil
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func release() {
        blocked?.resume()
        blocked = nil
    }
}

@MainActor private final class TimelineObservationCounter { var writes = 0 }

// MARK: - TaskDetailTimelineCopyTests

/// The Activity header's pure copy mapping (§4/§8): step counts with correct plurals, the
/// conversation-turn text, and "No tool calls recorded" proven only from the unfiltered member
/// inputs over a complete, settled history — never from filtered display rows alone.
@Suite struct TaskDetailTimelineCopyTests {

    private func task(_ fields: [String: JSONValue] = [:]) -> TaskInfo {
        var object: [String: JSONValue] = ["task_id": .string("t1"), "backend": .string("claude"), "status": .string("completed")]
        for (key, value) in fields { object[key] = value }
        return TaskInfo(.object(object))!
    }

    private func textItem(_ seq: Int, _ text: String) throws -> TimelineItem {
        let event = try #require(TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"assistant_text","text":"\#(text)"}"#))
        return try #require(Timeline.items(from: [event]).first)
    }

    private func toolItem(_ seq: Int) throws -> TimelineItem {
        let event = try #require(
            TaskEvent(line: #"{"v":1,"seq":\#(seq),"kind":"tool_call","call_id":"c\#(seq)","tool":"Read","category":"read","input_preview":""}"#)
        )
        return try #require(Timeline.items(from: [event]).first)
    }

    private func build(
        members: [ParallelMemberInput], history: EventHistoryState = EventHistoryState(), turnsText: String? = nil,
        status: String = "completed"
    ) throws -> TaskDetailTimelinePresentation {
        let input = TaskDetailTimelineInput(
            task: task(["status": .string(status)]), members: members, children: [], start: nil, isBuilder: false,
            events: [], snapshot: nil, history: history, turnsText: turnsText
        )
        return try TaskDetailTimelineBuilder.build(input)
    }

    private func member(items: [TimelineItem], availability: EventAvailability = .available, status: String = "completed") -> ParallelMemberInput {
        ParallelMemberInput(task: task(["status": .string(status)]), items: items, prompt: nil, availability: availability)
    }

    @Test(arguments: [("running", "Waiting for the first event…"), ("pending", "This task's event log is empty or was not found.")])
    func givenAnOpenedEmptyNonterminalLog_whenBuilt_thenOriginalEmptySurfaceRemainsWithoutANoToolClaim(status: String, emptyText: String) throws {
        // given — opening an empty file marks it available, but a nonterminal run can still append tools.
        let members = [member(items: [], status: status)]
        // when
        let presentation = try build(members: members, status: status)
        // then
        #expect(presentation.noToolCallsText == nil)
        #expect(presentation.emptyText == emptyText)
        #expect(presentation.stepCountText == nil)
    }

    @Test func givenAnOpenedProseOnlyRunningLog_whenBuilt_thenStepsRemainWithoutAFinalNoToolClaim() throws {
        // given
        let members = [member(items: [try textItem(1, "Still investigating.")], status: "running")]
        // when
        let presentation = try build(members: members, status: "running")
        // then
        #expect(presentation.noToolCallsText == nil)
        #expect(presentation.stepCountText == "1 step")
        #expect(presentation.emptyText == nil)
    }

    // MARK: Step counts: correct plurals, zero omitted

    @Test func givenOneItemRow_whenBuilt_thenTheHeaderSaysOneStep() throws {
        // given
        let members = [member(items: [try textItem(1, "Looked at the failing test.")])]
        // when
        let presentation = try build(members: members)
        // then
        #expect(presentation.stepCount == 1)
        #expect(presentation.stepCountText == "1 step")
    }

    @Test func givenSeveralItemRows_whenBuilt_thenTheHeaderUsesThePlural() throws {
        // given
        let members = [member(items: [try textItem(1, "First."), try textItem(2, "Second."), try textItem(3, "Third.")])]
        // when
        let presentation = try build(members: members)
        // then
        #expect(presentation.stepCountText == "3 steps")
    }

    @Test func givenNoItemRows_whenBuilt_thenTheStepCountIsOmittedNeverZero() throws {
        // given — nothing loaded yet: the count is omitted rather than claimed as "0 steps".
        // when
        let presentation = try build(members: [member(items: [])])
        // then
        #expect(presentation.stepCount == 0)
        #expect(presentation.stepCountText == nil)
    }

    // MARK: Conversation turns pass through unchanged

    @Test func givenAMultiMemberConversation_whenBuilt_thenTheTurnsTextPassesThrough() throws {
        // given / when
        let turns = try build(members: [member(items: [try textItem(1, "Prose.")])], turnsText: "3 turns")
        let decisions = try build(members: [member(items: [try textItem(1, "Prose.")])], turnsText: "2 decisions")
        // then — conversation members/orchestrator decisions, never the backend's own numTurns.
        #expect(turns.turnsText == "3 turns")
        #expect(decisions.turnsText == "2 decisions")
        #expect(turns.turnsText != decisions.turnsText)
    }

    // MARK: No-tool proof: only from complete, settled, unfiltered member inputs

    @Test func givenACompleteProseOnlyFeed_whenBuilt_thenStepsAndNoToolCallsRecordedShowTogether() throws {
        // given — a member whose own log was read completely, holding prose and nothing else.
        let members = [member(items: [try textItem(1, "Looked at the failing test.")])]
        // when
        let presentation = try build(members: members)
        // then — complete prose-only: the count AND the proven no-tool note.
        #expect(presentation.stepCountText == "1 step")
        #expect(presentation.noToolCallsText == "No tool calls recorded")
    }

    @Test func givenACompleteEmptyConversation_whenBuilt_thenOnlyNoToolCallsRecordedShows() throws {
        // given — the member exists and its log was read completely; it simply holds no items.
        let members = [member(items: [])]
        // when
        let presentation = try build(members: members)
        // then — the zero count is omitted; only the proven no-tool note remains.
        #expect(presentation.stepCountText == nil)
        #expect(presentation.noToolCallsText == "No tool calls recorded")
        #expect(presentation.emptyText == nil)
    }

    @Test func givenToolItemsInTheMemberInputs_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — a real tool item in the UNFILTERED member inputs. The claim is decided from this
        // source data, not from the filtered display rows, which managed/builder presentation may
        // intentionally hide calls from.
        let members = [member(items: [try textItem(1, "Prose."), try toolItem(2)])]
        // when
        let presentation = try build(members: members)
        // then
        #expect(presentation.stepCountText == "2 steps")
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenAnEmptyMemberInputSet_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — no member inputs at all: absence of members proves nothing.
        // when
        let presentation = try build(members: [])
        // then
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenAStillLoadingMemberLog_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — one member's own log has not finished loading.
        let members = [member(items: [try textItem(1, "Prose.")], availability: .loading)]
        // when
        let presentation = try build(members: members)
        // then
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenAnUnreadableMemberLog_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — a member's own log could not be read at all.
        let members = [member(items: [try textItem(1, "Prose.")], availability: .unavailable)]
        // when
        let presentation = try build(members: members)
        // then — never a false no-tools claim over a log nobody could read.
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenOlderHistoryStillLoading_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — the history window itself is mid-load.
        let members = [member(items: [try textItem(1, "Prose.")])]
        // when
        let presentation = try build(members: members, history: EventHistoryState(hasMore: true, isLoading: true))
        // then
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenMoreHistoryRemains_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — an unread older page could still hold tool calls.
        let members = [member(items: [try textItem(1, "Prose.")])]
        // when
        let presentation = try build(members: members, history: EventHistoryState(hasMore: true))
        // then
        #expect(presentation.noToolCallsText == nil)
    }

    @Test func givenAHistoryReadError_whenBuilt_thenNoNoToolClaimIsMade() throws {
        // given — the older-page read failed; the feed is explicitly not complete.
        let members = [member(items: [try textItem(1, "Prose.")])]
        // when
        let presentation = try build(members: members, history: EventHistoryState(error: "Synthetic read failure"))
        // then
        #expect(presentation.noToolCallsText == nil)
    }

    // MARK: The proof stays a pure input mapping

    @Test func givenAProvenToolFreeFeed_whenOlderHistoryStartsLoading_thenTheClaimClearsWithoutChangingRows() throws {
        // given
        let presentation = try build(members: [member(items: [try textItem(1, "Prose.")])])
        #expect(presentation.noToolCallsText != nil)
        // when
        let loading = presentation.loadingHistory()
        // then
        #expect(loading.noToolCallsText == nil)
        #expect(loading.history.isLoading)
        #expect(loading.rows == presentation.rows)
        #expect(loading.stepCountText == presentation.stepCountText)
    }

    @Test(arguments: [EventAvailability.loading, .unavailable])
    func givenAnIncompleteEmptyLog_whenBuilt_thenExistingLoadingOrUnavailableCopyIsRetained(availability: EventAvailability) throws {
        // given / when
        let presentation = try build(members: [member(items: [], availability: availability)])
        // then
        #expect(presentation.noToolCallsText == nil)
        #expect(presentation.emptyText == "This task's event log is empty or was not found.")
        #expect(presentation.isLoading == (availability == .loading))
    }

    @Test func givenTheSameMemberInputsAndHistory_whenTheNoToolProofIsChecked_thenTheAnswerIsStable() throws {
        // given — the proof reads no clock and no display state, so the same inputs always agree.
        let items = [try textItem(1, "Prose.")]
        let members = [member(items: items)]
        let history = EventHistoryState()
        // when / then
        #expect(TaskDetailTimelinePresentation.noToolCallsRecorded(members: members, history: history))
        #expect(TaskDetailTimelinePresentation.noToolCallsRecorded(members: members, history: history))
        var fewer = members
        fewer[0] = member(items: [])
        #expect(TaskDetailTimelinePresentation.noToolCallsRecorded(members: fewer, history: history))
    }
}
