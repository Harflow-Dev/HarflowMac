import AppKit
import HfRepository
import HfTestUtilities
@testable import MainWindowFeature
import Mockable
import MonitorCore
import Testing

// MARK: - M05TranscriptStateMatrixHostedTests

/// Native evidence for the eight transcript states (`screens-transcript.js`, approved 2026-11-08), the task `loading` state
/// (`screens-loading-work.js`) and the pending caller `approval` card (`registry.js`, `task/approval`), each in the production
/// shell with a real standalone `TaskDetailVM`. `loading-pane` is listed in the state table and not mounted: the skeleton
/// has no pane. The transcript states open the pane on Events so the request, history and totals are all on screen.
@MainActor
@Suite(.serialized)
struct M05TranscriptStateMatrixHostedTests {
    nonisolated static let states = M05StateTable.ids(.transcript)

    @Test(arguments: states, [false, true])
    func givenApprovedTranscriptState_whenHostedInBothSizes_thenNativeStateRenders(state: String, dark: Bool) async throws {
        // given / when / then
        try await M05MatrixRunner.run(Self.spec(state), dark: dark)
    }

    // MARK: Recipes

    static func spec(_ state: String) -> M05MatrixRunner.Spec {
        switch state {
        case "loading": loading()
        case "approval": approval()
        default: transcript(state)
        }
    }

    private static func scenario(_ state: String) -> String {
        state == "transcript-sources" ? "events" : String(state.dropFirst("transcript-".count))
    }

    /// The observation frame of a scenario, as `ObservationHostedTests` builds it, with rows for the observed state.
    private static func frame(_ scenario: String) -> EventObservationFrame {
        let rows = [M05Fixtures.text(1, "Captured activity stays readable."), M05Fixtures.text(2, "The retry path re-checks the count.")]
        let history: EventObservationHistory = switch scenario {
        case "loading": .init(isLoading: true)
        case "reconnecting": .init(reasons: [.gaps], currentness: .reconnecting, availableActions: [.retryRead])
        case "capacity": .init(reasons: [.capacity], availableActions: [.rebaseWindow])
        case "events": .init(reasons: [.unknownKind], currentness: .sourceChangePending,
                             availableActions: [.loadEarlier, .retryRead, .adoptCurrentSource])
        case "observed": .init(caughtUp: true, forwardDrained: true)
        default: .init(reasons: [.gaps], availableActions: [.retryRead])
        }
        let records: [ObservedEventRecord] = scenario == "events" ? [7, 7, 6].enumerated().map { admission, sequence in
            let raw: [String: JSONValue] = ["product": .string("harflow"), "format": .string("harflow.event"),
                "v": .number(1), "product_version": .string("0.0.8"), "seq": .number(Double(sequence)),
                "observed_at": .null, "kind": .string(admission == 1 ? "tool_result" : "future_kind"),
                "truncated": .bool(true), "oversized": .bool(false)]
            return ObservedEventRecord(id: .init(scope: FeatureObservationFixture.scope, admission: admission), record: TaskEventRecord(raw: raw)!)
        } : []
        let summary: ObservedActivitySummary = switch scenario {
        case "loading": .init(state: .loading)
        case "capacity", "observed": .init(state: .observed, counts: ActivityCounts(), totalFiles: 0)
        default: .init(state: .unavailable)
        }
        return EventObservationFrame(taskID: M05Fixtures.taskID, scope: FeatureObservationFixture.scope, records: records,
                                     items: scenario == "loading" ? [] : rows, history: history, summary: summary)
    }

    private static func request(_ scenario: String) throws -> TaskRequestReadState {
        if scenario == "loading" { return .loading(maxBytes: 65536) }
        let failed = scenario == "integrity-failed"
        let unavailable = scenario == "unavailable"
        let text = failed || unavailable ? nil : "  Stored assignment prefix.\nPreserve whitespace and provenance.\n"
        let prompt: [String: JSONValue] = ["state": .string(failed ? "integrity_failed" : unavailable ? "unavailable" : "available"),
            "integrity": .string(failed ? "failed" : unavailable ? "not_applicable" : "unverified"),
            "text": text.map(JSONValue.string) ?? .null, "returned_bytes": .number(Double(text?.utf8.count ?? 0)),
            "total_bytes": .null, "truncated": .bool(false), "complete": .bool(false)]
        let value = try #require(TaskPromptResult(raw: ["task_id": .string(M05Fixtures.taskID), "title": .string("Fixture"),
                                                        "prompt": .object(prompt)]))
        return .received(value, maxBytes: 65536)
    }

    private static func recoveredFrame(_ name: String) -> RecoveredTranscriptFrame {
            guard name == "events" else { return RecoveredTranscriptFrame() }
            let event = TaskEvent(seq: 7, displayID: 0, observedAt: nil, sourceTimestamp: nil,
                kind: .assistantText(text: "Recovered evidence", messageID: nil, blockIndex: nil),
                rawLine: "Recovered evidence from a separately qualified transcript")
            return RecoveredTranscriptFrame(generation: UUID(), events: [event], items: Timeline.items(from: [event]))
    }

    private static func historyNotice(_ name: String) -> String? {
        switch name {
        case "loading": "Loading captured history"
        case "reconnecting": "Captured history unavailable"
        case "capacity": "This view's activity limit has been reached. Retained rows and reading position are preserved."
        case "events": "Activity source changed · cached history is not current"
        case "observed": "Captured activity caught up"
        default: "History incomplete or unavailable · see Events"
        }
    }

    private static func transcript(_ state: String) -> M05MatrixRunner.Spec {
        let name = scenario(state)
        let task = M05Fixtures.settled()
        let frame = frame(name)
        let recovered = recoveredFrame(name)
        let historyText = historyNotice(name)
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.transcript.rawValue, state: state, config: { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = "Fix the flaky retry path in the slot release"
            config.notices = 0
            config.continuity = false
            // The Events pane carries the sources and totals; the other states keep the transcript region on its own.
            config.openPane = state == "transcript-sources"
            config.closePane = state != "transcript-sources"
            config.paneTab = .events
            return config
        }, build: {
            let harness = M05Fixtures.harness(task)
            harness.observationBox.value = frame
            harness.requestBox.value = try request(name)
            harness.recoveryBox.value = recovered
            return .init(harness: harness)
        }, drive: { ctx in
            ctx.harness.tasksSubject.send([task])
            M05Fixtures.publish(frame, to: ctx.harness)
            ctx.harness.recoverySubject.send(recovered)
            ctx.harness.requestSubject.send(ctx.harness.requestBox.value)
        }, ready: { ctx in
            let sources = state == "transcript-sources"
            // In the 1000 x 620 overlay the modal pane hides the transcript column's own views from accessibility.
            let overlay = sources && ctx.size.width < 1100
            if sources, !ctx.has("Public normalized events · bounded record window") { return false }
            return overlay || historyText.map { ctx.hasContaining($0) } != false
        }, verify: { ctx in
            let overlay = state == "transcript-sources" && ctx.size.width < 1100
            if overlay {
                #expect(ctx.has("Public normalized events · bounded record window"))
                #expect(ctx.has("Recovered transcript"), "recovered source labelled \(ctx.name)")
                return
            }
            let heading = StoredRequestPresentation(state: ctx.harness.requestBox.value).heading
            #expect(ctx.hasContaining(heading), "request disclosure \(heading) \(ctx.name)")
            if let historyText { #expect(ctx.hasContaining(historyText), "boundary notice \(historyText) \(ctx.name)") }
            let actions = frame.history.availableActions
            for (action, label) in [(EventObservationAction.loadEarlier, "Load earlier"), (.retryRead, "Retry history read"),
                                    (.rebaseWindow, "Load current activity"), (.adoptCurrentSource, "Load current activity from new source")] {
                #expect(ctx.has(label) == actions.contains(action), "history action \(label) \(ctx.name)")
            }
            // Missing totals are never shown as zero.
            if name == "loading" {
                #expect(!ctx.hasContaining("No tool calls observed"), "loading is not zero \(ctx.name)")
            } else if frame.summary.state == .unavailable {
                #expect(!ctx.hasContaining("No tool calls observed"), "unavailable is not zero \(ctx.name)")
            }
            if name == "events" {
                #expect(ctx.has("Public normalized events · bounded record window"))
                #expect(ctx.has("Recovered transcript"), "recovered source labelled \(ctx.name)")
                #expect(ctx.has("future_kind") || ctx.hasContaining("future_kind"), "normalized records listed \(ctx.name)")
            }
        })
    }

    // MARK: Loading

    private static func loading() -> M05MatrixRunner.Spec {
        M05MatrixRunner.Spec(suite: M05StateTable.Suite.transcript.rawValue, state: "loading", config: { _ in
            var config = TopBarIntegratedFixture.Config()
            config.loading = true
            return config
        }, build: {
            // The task has not been listed: no detail, and `hasListedSubject` never sends.
            .init(harness: M05Fixtures.harness(nil))
        }, ready: { ctx in ctx.has("Loading task") }, verify: { ctx in
            #expect(ctx.vm.task == nil && !ctx.vm.hasListed, "the VM has not listed \(ctx.name)")
            #expect(ctx.has("Loading task"), "skeleton drawn \(ctx.name)")
            #expect(ctx.fixture.item(TopBarIntegratedFixture.more) != nil || !ctx.fixture.items.isEmpty, "toolbar frame \(ctx.name)")
            #expect(!ctx.fixture.hasPane, "no pane in the skeleton \(ctx.name)")
            #expect(!ctx.has("Stop"), "no Stop control while loading \(ctx.name)")
        })
    }

    // MARK: Approval

    @MainActor private final class ApprovalProbe: CallerApprovalUseCase {
        private let request = CallerApprovalRequest(raw: [
            "request_id": .string("matrix-approval"), "task_id": .string(M05Fixtures.taskID),
            "action_digest": .string(String(repeating: "a", count: 64)), "owner_revision": .number(1),
            "generation": .string("generation-1"), "interaction_owner": .string("monitor"),
            "disposition": .string("pending"), "delivery": .string("pending"), "execution_outcome": .string("unknown"),
            "tool_name": .string("Bash"), "cwd": .string("/repo"), "freedom": .string("write_in_repo"), "scope": .string("matrix"),
            "deadline": .number(Date().addingTimeInterval(600).timeIntervalSince1970), "complete": .bool(true),
            "action": .object(["tool_name": .string("Bash"), "input": .object(["command": .string("echo matrix")])])
        ])
        func page(taskID: String?, workflowRunID: String?, cursor: String?) async throws -> CallerApprovalPage {
            CallerApprovalPage(requests: [request], total: 1)
        }

        func detail(_ request: CallerApprovalRequest) async throws -> CallerApprovalRequest { request }
        func respond(_ request: CallerApprovalRequest, decision: String) async throws -> CallerApprovalRequest { request }
        func supportsMonitorResponseForCallerApprovals() async throws -> Bool { true }
    }

    private static func approval() -> M05MatrixRunner.Spec {
        let task = M05Fixtures.task(status: "running", fields: ["caller_approvals": .bool(true)])
        let probe = ApprovalProbe()
        return M05MatrixRunner.Spec(suite: M05StateTable.Suite.transcript.rawValue, state: "approval", config: { _ in
            var config = TopBarIntegratedFixture.Config()
            config.title = "Fix the flaky retry path in the slot release"
            config.notices = 0
            config.continuity = false
            config.closePane = true
            return config
        }, build: {
            let harness = M05Fixtures.harness(task)
            harness.callerApprovalBox.value = probe
            return .init(harness: harness, retained: [probe])
        }, drive: { ctx in ctx.harness.tasksSubject.send([task]) }, ready: { ctx in
            ctx.has("Approve once") && ctx.has("Reject")
        }, verify: { ctx in
            #expect(ctx.has("Approve once") && ctx.has("Reject"), "exact action copy \(ctx.name)")
            #expect(ctx.hasContaining("Answered from Harflow") || ctx.hasContaining("Working directory: /repo"), "source attribution \(ctx.name)")
            #expect(ctx.hasContaining("Access level: write_in_repo"), "access level \(ctx.name)")
        })
    }
}
