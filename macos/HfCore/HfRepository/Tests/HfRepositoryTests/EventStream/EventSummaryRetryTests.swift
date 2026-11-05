import Foundation
@testable import HfRepository
import HfTestUtilities
import MonitorCore
import Testing

// MARK: - EventSummaryRetryTests

@Suite struct EventSummaryRetryTests {
    @Test func givenSummaryReadFailure_whenExplicitReadRetryCompletes_thenUnknownDoesNotBecomeZeroOrLoseCursorLineage() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "file")], newer: "frontier")))
        await waitUntil { harness.reader.requests.count == 2 }
        harness.reader.finish(1, .failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline")))
        await waitUntil { sut.observation(for: "task").history.availableActions.contains(.retryRead) }
        #expect(sut.observation(for: "task").summary.counts == nil)
        let scope = sut.observation(for: "task").scope
        // when
        #expect(sut.requestObservation(action: .retryRead, for: "task", scope: scope))
        await waitUntil { harness.reader.requests.count == 3 }
        #expect(harness.reader.requests[2].position == .cursor("frontier"))
        harness.reader.finish(2, .success(ObservationFixtures.page(newer: "frontier")))
        await waitUntil { harness.reader.requests.count == 4 }
        harness.reader.finish(3, .success(ObservationFixtures.page(newer: "frontier")))
        await waitUntil { sut.observation(for: "task").summary.state == .observed }
        // then
        #expect(sut.observation(for: "task").summary.counts?.edits == 1)
        #expect(sut.observation(for: "task").scope == scope)
        #expect(harness.reader.requests.filter { $0.position == .newest }.count == 1)
    }

    @Test func givenInitialPublicHandshakeFailure_whenExplicitRetryRecovers_thenSummaryLeavesUnavailableOnlyAfterQualifiedTraversal() async {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .failure(.refused(code: "missing_capability", message: "public history unavailable")))
        await waitUntil { sut.observation(for: "task").history.availableActions.contains(.retryRead) }
        #expect(sut.observation(for: "task").summary.state == .unavailable)
        #expect(sut.observation(for: "task").summary.counts == nil)
        // when
        let scope = sut.observation(for: "task").scope
        #expect(sut.requestObservation(action: .retryRead, for: "task", scope: scope))
        await waitUntil { harness.reader.requests.count == 2 }
        #expect(harness.reader.requests[1].position == .newest)
        harness.reader.finish(1, .success(ObservationFixtures.page([ObservationFixtures.call(1, id: "edit", path: "file")])))
        await waitUntil { harness.reader.requests.count == 3 }
        harness.reader.finish(2, .success(ObservationFixtures.page()))
        await waitUntil { sut.observation(for: "task").summary.state == .observed }
        // then
        #expect(sut.observation(for: "task").summary.counts?.edits == 1)
        #expect(sut.observation(for: "task").scope == scope)
    }

    @Test func givenUnsupportedPromptReadSizes_whenRequested_thenOnlyDefaultAndOneQualifiedLargerReadAreAdmitted() async throws {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        // when
        sut.readRequest(for: "task", maxBytes: 1)
        sut.readRequest(for: "task", maxBytes: 131072)
        #expect(harness.prompts.requests.isEmpty)
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        #expect(harness.prompts.requests[0].maxBytes == 65536)
        let prefix = try #require(prompt(text: "prefix", truncated: true))
        harness.prompts.finish(0, .success(prefix))
        await waitUntil { sut.requestState(for: "task") == .received(prefix, maxBytes: 65536) }
        sut.readRequest(for: "task", maxBytes: 131072)
        await waitUntil { harness.prompts.requests.count == 2 }
        #expect(harness.prompts.requests[1].maxBytes == 131072)
        let expanded = try #require(prompt(text: "prefix plus", truncated: true))
        harness.prompts.finish(1, .success(expanded))
        await waitUntil { sut.requestState(for: "task") == .received(expanded, maxBytes: 131072) }
        sut.readRequest(for: "task", maxBytes: 131072)
        sut.readRequest(for: "task", maxBytes: 131073)
        // then
        #expect(harness.prompts.requests.count == 2)
        #expect(sut.requestState(for: "task") == .received(expanded, maxBytes: 131072))
        #expect(sut.observation(for: "task").records.isEmpty)
    }

    @Test(arguments: ["preview", "unverified"])
    func givenPartialNontruncatedRequest_whenReadMoreRequested_thenLargerBoundedReplacementIsAdmitted(qualification: String) async throws {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        let partial = try #require(partialPrompt(qualification: qualification))
        harness.prompts.finish(0, .success(partial))
        await waitUntil { sut.requestState(for: "task") == .received(partial, maxBytes: 65536) }
        // when
        sut.readRequest(for: "task", maxBytes: 131072)
        await waitUntil { harness.prompts.requests.count == 2 }
        let replacement = try #require(prompt(text: "replacement"))
        harness.prompts.finish(1, .success(replacement))
        await waitUntil { sut.requestState(for: "task") == .received(replacement, maxBytes: 131072) }
        // then
        #expect(harness.prompts.requests[1].maxBytes == 131072)
        #expect(!partial.truncated)
        #expect(!partial.complete)
        #expect(sut.observation(for: "task").records.isEmpty)
    }

    @Test func givenFailedLargerRequest_whenExplicitlyRetried_thenSameBoundCanRecoverAndFreshDefaultStartsAnotherBoundedCycle() async throws {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        let prefix = try #require(prompt(text: "prefix", truncated: true))
        harness.prompts.finish(0, .success(prefix))
        await waitUntil { sut.requestState(for: "task") == .received(prefix, maxBytes: 65536) }
        sut.readRequest(for: "task", maxBytes: 131072)
        await waitUntil { harness.prompts.requests.count == 2 }
        let failure = ToolError.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "offline")
        harness.prompts.finish(1, .failure(failure))
        await waitUntil { sut.requestState(for: "task") == .failed(failure, maxBytes: 131072) }
        // when
        sut.readRequest(for: "task", maxBytes: 131072)
        await waitUntil { harness.prompts.requests.count == 3 }
        let expanded = try #require(prompt(text: "expanded", truncated: true))
        harness.prompts.finish(2, .success(expanded))
        await waitUntil { sut.requestState(for: "task") == .received(expanded, maxBytes: 131072) }
        sut.readRequest(for: "task", maxBytes: 131072)
        #expect(harness.prompts.requests.count == 3)
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 4 }
        harness.prompts.finish(3, .success(prefix))
        await waitUntil { sut.requestState(for: "task") == .received(prefix, maxBytes: 65536) }
        sut.readRequest(for: "task", maxBytes: 131072)
        await waitUntil { harness.prompts.requests.count == 5 }
        harness.prompts.finish(4, .success(expanded))
        await waitUntil { sut.requestState(for: "task") == .received(expanded, maxBytes: 131072) }
        // then
        #expect(harness.prompts.requests.map(\.maxBytes) == [65536, 131072, 131072, 65536, 131072])
    }

    @Test func givenSupersededPromptRead_whenLateSuccessArrives_thenNewestFailureRemainsVisible() async throws {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        defer { lease.release() }
        await waitUntil { harness.reader.requests.count == 1 }
        harness.reader.finish(0, .success(ObservationFixtures.page(capture: "future_capture")))
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        // when
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 2 }
        let failure = ToolError.refused(code: "unavailable", message: "request unavailable")
        harness.prompts.finish(1, .failure(failure))
        await waitUntil { sut.requestState(for: "task") == .failed(failure, maxBytes: 65536) }
        harness.prompts.finish(0, .success(try #require(prompt(text: "stale"))))
        // then
        #expect(!harness.prompts.requests[0].current())
        #expect(sut.requestState(for: "task") == .failed(failure, maxBytes: 65536))
        #expect(sut.prompt(for: "task") == nil)
    }

    @Test func givenPromptReadInFlight_whenRuntimeChangesAndLeaseReleases_thenLateRequestCannotReviveOldState() async throws {
        // given
        let harness = PublicEventFacadeHarness()
        let sut = harness.repository
        let lease = sut.acquire("task")
        await waitUntil { harness.reader.requests.count == 1 }
        sut.readRequest(for: "task", maxBytes: 65536)
        await waitUntil { harness.prompts.requests.count == 1 }
        // when
        sut.invalidateRuntime()
        await waitUntil { harness.reader.requests.count == 2 }
        lease.release()
        harness.prompts.finish(0, .success(try #require(prompt(text: "obsolete"))))
        harness.reader.finish(0, .success(ObservationFixtures.page([ObservationFixtures.record(1)])))
        harness.reader.finish(1, .failure(.unreadable(tool: "harflow-ctl", exitCode: 1, stderr: "obsolete")))
        // then
        #expect(!harness.prompts.requests[0].current())
        #expect(sut.requestState(for: "task") == .notRequested)
        #expect(sut.observation(for: "task").records.isEmpty)
        #expect(sut.leasedTaskIDs.isEmpty)
    }

    private func partialPrompt(qualification: String) -> TaskPromptResult? {
        let preview = qualification == "preview"
        let text = "partial"
        return TaskPromptResult(raw: ["task_id": .string("task"), "title": .string("Task"), "prompt": .object([
            "state": .string(preview ? "preview_only" : "available"), "text": .string(text),
            "returned_bytes": .number(Double(text.utf8.count)), "total_bytes": .null, "complete": .bool(false),
            "truncated": .bool(false), "integrity": .string(preview ? "not_applicable" : "unverified")])])
    }

    private func prompt(text: String, truncated: Bool = false) -> TaskPromptResult? {
        TaskPromptResult(raw: ["task_id": .string("task"), "title": .string("Task"), "prompt": .object([
            "state": .string("available"), "text": .string(text), "returned_bytes": .number(Double(text.utf8.count)),
            "total_bytes": .number(Double(text.utf8.count + (truncated ? 10 : 0))), "complete": .bool(!truncated),
            "truncated": .bool(truncated), "integrity": .string("verified")])])
    }
}
