import Combine
import Foundation
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

@MainActor
extension TaskDetailVMTests {
    @Test func givenLoadingFrame_whenAtomicRowsAndHistoryArrive_thenCompletedHistoryNeverPrecedesItsRows() async throws {
        // given
        let harness = makeSUT()
        let member = task(status: "completed")
        harness.detailBox.value = member
        harness.observationBox.value = FeatureObservationFixture.frame(id: member.taskID)
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.timelineWorker == nil && harness.sut.latestTimelineInput != nil }
        #expect(harness.sut.observationFrames[member.taskID]?.history.isLoading == true)
        #expect(harness.sut.timelineModel.noToolCallsText == nil)
        let event = try observedText(sequence: 7, admission: 0, text: "admitted atomically")
        let frame = FeatureObservationFixture.frame(id: member.taskID, events: [event],
            items: Timeline.items(from: [event]), availability: .available)
        // when
        harness.observationBox.value = frame
        harness.observationSubject.send(frame)
        // then
        await waitUntil { harness.sut.observationFrames[member.taskID] == frame && harness.sut.timelineWorker == nil }
        #expect(harness.sut.observationFrames[member.taskID]?.items.count == 1)
        #expect(harness.sut.observationFrames[member.taskID]?.history.isLoading == false)
        #expect(harness.sut.timelineModel.rows.count == 1)
        harness.sut.didDisappear()
    }

    @Test func givenStoredRequestReads_whenBoundsRequested_thenPublicReadUsesNativeCeilingAndNeverZero() async {
        // given
        let harness = makeSUT()
        harness.detailBox.value = task()
        harness.sut.didAppear()
        harness.tasksSubject.send([task()])
        await waitUntil { harness.sut.requestTaskID != nil }
        // when
        harness.sut.didReadRequest(maxBytes: 0)
        harness.sut.didReadRequest(maxBytes: Int.max)
        // then
        verify(harness.useCase).readRequest(for: .value("abc12345"), maxBytes: .value(65536)).called(1)
        verify(harness.useCase).readRequest(for: .value("abc12345"), maxBytes: .value(1)).called(1)
        verify(harness.useCase).readRequest(for: .value("abc12345"), maxBytes: .value(131072)).called(1)
        harness.sut.didDisappear()
    }

    @Test(arguments: [true, false])
    func givenRequestCopy_whenClipboardReturns_thenFeedbackMatchesActualWrite(success: Bool) {
        // given
        let harness = makeSUT()
        let text = "  stored request\n\nexact spacing  "
        given(harness.routing).copyToPasteboard(.value(text)).willReturn(success)
        // when
        harness.sut.didCopyObservationText(text)
        // then
        verify(harness.routing).copyToPasteboard(.value(text)).called(1)
        #expect(harness.sut.copyFeedback == (success ? "Copied" : "Select the displayed text and use your system copy command to copy it."))
    }

    @Test(arguments: [EventObservationAction.rebaseWindow, .adoptCurrentSource, .retryRead])
    func givenRetainedWindowWithPendingSource_whenObservationActionRequested_thenExactRetainedScopeIsForwarded(action: EventObservationAction) async {
        // given
        let harness = makeSUT()
        let member = task(status: "completed")
        let scope = FeatureObservationFixture.scope
        let frame = EventObservationFrame(taskID: member.taskID, scope: scope,
            history: .init(reasons: [.capacity, .gaps], currentness: .sourceChangePending,
                availableActions: [.rebaseWindow, .adoptCurrentSource, .retryRead]),
            summary: .init(state: .unavailable, reasons: [.gaps]))
        harness.detailBox.value = member
        harness.observationBox.value = frame
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.observationFrames[member.taskID] == frame }
        given(harness.useCase).loadMoreEvents(.value(member.taskID)).willReturn(false)
        // when
        harness.sut.didRequestObservation(action, taskID: member.taskID)
        // then
        verify(harness.useCase).requestObservation(.value(action), for: .value(member.taskID), scope: .value(scope)).called(1)
        #expect(harness.sut.observationFrames[member.taskID] == frame, "a read request cannot silently adopt or evict retained evidence")
        #expect(harness.sut.task?.status == .completed, "observation failure does not alter execution status")
        harness.sut.didDisappear()
    }

    @Test func givenRecoveredTranscriptWithTools_whenSummaryRecomputes_thenCapturedCountsKeepTheirOwnProvenance() async throws {
        // given
        let harness = makeSUT()
        let member = task(status: "completed")
        harness.detailBox.value = member
        let captured = FeatureObservationFixture.frame(id: member.taskID, availability: .available)
        harness.observationBox.value = captured
        harness.sut.didAppear()
        harness.tasksSubject.send([member])
        await waitUntil { harness.sut.observationFrames[member.taskID] == captured }
        let eventLine = #"{"product":"harflow","format":"harflow.event","v":1,"product_version":"1.0.0","seq":7,"#
            + #""kind":"tool_call","call_id":"recovered-call","tool":"Read","category":"read","input_preview":"recovered"}"#
        let event = try #require(TaskEvent(line: eventLine))
        let recovery = RecoveredTranscriptFrame(generation: UUID(), events: [event], items: Timeline.items(from: [event]))
        // when
        harness.sut.recoveredTranscript = recovery
        harness.sut.recompute()
        // then
        #expect(harness.sut.recoveredTranscript == recovery)
        #expect(harness.sut.observationFrames[member.taskID] == captured)
        #expect(harness.sut.observationFrames[member.taskID]?.summary.counts?.toolCalls == 0)
        #expect(harness.sut.observationFrames[member.taskID]?.events.isEmpty == true)
        harness.sut.didDisappear()
    }

    private func observedText(sequence: Int, admission: Int, text: String) throws -> TaskEvent {
        let raw: [String: JSONValue] = ["seq": .number(Double(sequence)), "kind": .string("assistant_text"), "text": .string(text)]
        return TaskEvent(seq: sequence, displayID: admission, observedAt: nil, sourceTimestamp: nil,
            kind: .assistantText(text: text, messageID: nil, blockIndex: nil), rawLine: JSONValue.object(raw).rendered())
    }
}

@Suite struct PublicObservationQualificationTests {
    private func member(_ frame: EventObservationFrame?) -> ParallelMemberInput {
        let task = TaskInfo(.object(["task_id": .string("observed"), "status": .string("completed")]))!
        return ParallelMemberInput(task: task, items: frame?.items ?? [], prompt: nil,
            availability: frame?.presentationAvailability ?? .available, observation: frame)
    }

    @Test func givenUnavailableOrLoadingSummary_whenWindowIsEmpty_thenNoToolsCannotBeInferred() {
        // given / when / then
        for state in [ObservedActivitySummary.State.loading, .unavailable, .limited] {
            let frame = EventObservationFrame(taskID: "observed", scope: FeatureObservationFixture.scope,
                history: .init(caughtUp: true, forwardDrained: true), summary: .init(state: state, counts: ActivityCounts(), totalFiles: 0))
            #expect(frame.summary.counts == nil)
            #expect(frame.summary.totalFiles == nil)
            #expect(!TaskDetailTimelinePresentation.noToolCallsRecorded(members: [member(frame)], history: .init()))
        }
        #expect(!TaskDetailTimelinePresentation.noToolCallsRecorded(members: [member(nil)], history: .init()))
    }

    @Test func givenQualifiedZero_whenCoverageOrCurrentnessChanges_thenNoToolsProofFailsClosed() {
        // given
        let summary = ObservedActivitySummary(state: .observed, counts: ActivityCounts(), totalFiles: 0)
        let scope = FeatureObservationFixture.scope
        let qualified = EventObservationFrame(taskID: "observed", scope: scope,
            history: .init(caughtUp: true, forwardDrained: true), summary: summary)
        #expect(TaskDetailTimelinePresentation.noToolCallsRecorded(members: [member(qualified)], history: .init()))
        // when / then
        for history in [EventObservationHistory(caughtUp: false),
                        .init(caughtUp: true, reasons: [.gaps]),
                        .init(caughtUp: true, reasons: [.unknownKind]),
                        .init(caughtUp: true, currentness: .reconnecting),
                        .init(caughtUp: true, currentness: .sourceChangePending)] {
            let frame = EventObservationFrame(taskID: "observed", scope: scope, history: history, summary: summary)
            #expect(!TaskDetailTimelinePresentation.noToolCallsRecorded(members: [member(frame)], history: .init()))
        }
    }

    @Test func givenTypedMissingCapabilityFailure_whenHistoryPresented_thenPublicReasonIsPreservedWithoutMetadataFallback() {
        // given
        let failure = ToolError.unsupportedCommand(tool: "harflow-ctl", command: "task-events",
            detail: "Selected engine lacks the public task event paging capability")
        let frame = EventObservationFrame(taskID: "observed", scope: FeatureObservationFixture.scope,
            history: .init(reasons: [.unavailable], failure: failure),
            summary: .init(state: .unavailable, reasons: [.unavailable]))
        // when
        let presentation = frame.presentationHistory
        // then
        #expect(presentation.error == failure.message)
        #expect(frame.history.failure == failure)
        #expect(frame.presentationAvailability == .unavailable)
        #expect(frame.items.isEmpty && frame.events.isEmpty && frame.records.isEmpty)
        #expect(frame.summary.counts == nil)
    }

    @Test func givenWindowCapacity_whenIndependentSummaryIsSound_thenObservedCountsRemainAvailable() {
        // given
        var counts = ActivityCounts()
        counts.toolCalls = 2
        let frame = EventObservationFrame(taskID: "observed", scope: FeatureObservationFixture.scope,
            history: .init(reasons: [.capacity], availableActions: [.rebaseWindow]),
            summary: .init(state: .observed, counts: counts, totalFiles: 0))
        // when / then
        #expect(frame.summary.counts?.toolCalls == 2)
        #expect(frame.history.availableActions == [.rebaseWindow])
        #expect(!TaskDetailTimelinePresentation.noToolCallsRecorded(members: [member(frame)], history: .init()))
    }

    @Test func givenRepeatedRegressingSequences_whenRowsPrependOrWindowChanges_thenOccurrenceOrderAndScopeRemainDistinct() throws {
        // given
        let task = member(nil).task
        let events = [7, 7, 6].enumerated().map { index, sequence in
            TaskEvent(seq: sequence, displayID: index, observedAt: nil, sourceTimestamp: nil,
                kind: .assistantText(text: "Occurrence \(index)", messageID: nil, blockIndex: nil), rawLine: "{}")
        }
        let items = Timeline.items(from: events)
        let scope = FeatureObservationFixture.scope
        let rows = try ParallelPresentationBuilder.rows([.init(task: task, items: items, prompt: nil, identityScope: scope.identity)])
        // when
        let suffix = try ParallelPresentationBuilder.rows([.init(task: task, items: Array(items.suffix(2)), prompt: nil, identityScope: scope.identity)])
        let rebased = EventObservationScope(sessionID: scope.sessionID, sourceID: scope.sourceID, windowID: UUID())
        let next = try ParallelPresentationBuilder.rows([.init(task: task, items: items, prompt: nil, identityScope: rebased.identity)])
        // then
        #expect(events.map(\.seq) == [7, 7, 6])
        #expect(items.map(\.id) == [0, 1, 2])
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.id)).count == 3)
        #expect(Array(rows.suffix(2)).map(\.id) == suffix.map(\.id))
        #expect(Set(rows.map(\.id)).isDisjoint(with: next.map(\.id)))
    }
}

@Suite struct StoredRequestQualificationTests {
    private func request(state: String = "available", integrity: String = "verified", text: String? = "  exact request\n\n",
                         complete: Bool = true, truncated: Bool = false) throws -> TaskPromptResult {
        let raw: [String: JSONValue] = ["task_id": .string("stored"), "title": .string("Stored request"),
            "prompt": .object(["state": .string(state), "integrity": .string(integrity),
                "text": text.map(JSONValue.string) ?? .null, "returned_bytes": .number(Double(text?.utf8.count ?? 0)),
                "total_bytes": complete ? .number(Double(text?.utf8.count ?? 0)) : .null,
                "complete": .bool(complete), "truncated": .bool(truncated)])]
        return try #require(TaskPromptResult(raw: raw))
    }

    @Test(arguments: ["verified", "not_applicable"])
    func givenCompleteStoredRequest_whenPresented_thenExactTextAndFullCopyAreQualified(integrity: String) throws {
        // given
        let value = try request(integrity: integrity)
        // when
        let presentation = StoredRequestPresentation(state: .received(value, maxBytes: 65536))
        // then
        #expect(presentation.heading == "Original request")
        #expect(presentation.text == "  exact request\n\n")
        #expect(presentation.isFull)
        #expect(presentation.copyLabel == "Copy original request")
        #expect(presentation.readMoreBytes == nil)
        #expect(presentation.provenance == (integrity == "verified" ? "Verified stored request" : "Complete stored request"))
    }

    @Test func givenPreviewOrUnverifiedPrefix_whenPresented_thenNeverClaimsFullAssignment() throws {
        // given
        let preview = try request(state: "preview_only", integrity: "not_applicable", complete: false)
        let unverified = try request(integrity: "unverified", complete: false)
        let truncated = try request(complete: false, truncated: true)
        // when / then
        for (value, heading, copy) in [(preview, "Request preview", "Copy preview"),
                                       (unverified, "Partial request", "Copy displayed text"),
                                       (truncated, "Partial request", "Copy displayed text")] {
            let presentation = StoredRequestPresentation(state: .received(value, maxBytes: 65536))
            #expect(!presentation.isFull)
            #expect(presentation.heading == heading)
            #expect(presentation.copyLabel == copy)
            #expect(presentation.text == value.text)
            #expect(presentation.readMoreBytes == 131072)
            let ceiling = StoredRequestPresentation(state: .received(value, maxBytes: 131072))
            #expect(ceiling.readMoreBytes == nil)
            #expect(!ceiling.isFull)
        }
        #expect(StoredRequestPresentation(state: .received(unverified, maxBytes: 65536)).provenance == "Unverified text · completeness unknown")
    }

    @Test func givenLoadingUnavailableOrIntegrityFailure_whenPresented_thenTextAndCopyAreWithheld() throws {
        // given
        let unavailable = try request(state: "unavailable", integrity: "not_applicable", text: nil, complete: false)
        let failed = try request(state: "integrity_failed", integrity: "failed", text: nil, complete: false)
        // when / then
        for state in [TaskRequestReadState.notRequested, .loading(maxBytes: 65536),
                      .received(unavailable, maxBytes: 65536), .received(failed, maxBytes: 65536)] {
            let presentation = StoredRequestPresentation(state: state)
            #expect(presentation.text == nil)
            #expect(presentation.copyLabel == nil)
            #expect(presentation.readMoreBytes == nil)
            #expect(!presentation.isFull)
        }
        #expect(StoredRequestPresentation(state: .received(failed, maxBytes: 65536)).heading == "Original request · integrity check failed")
    }
}
