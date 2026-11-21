import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

struct WorkflowSteeringPresentationTests {
    private let rootID = WorkflowSteeringTestFixtures.rootRunID
    private let episodeID = WorkflowSteeringTestFixtures.episodeID
    private let turnID = WorkflowSteeringTestFixtures.turnID

    @Test func givenCancelledRootWithEarlierConversation_whenMakingPresentation_thenKeepsConversationAndLocksComposer() throws {
        // given
        let status = try WorkflowSteeringTestFixtures.status(state: "awaiting_caller", held: true, eligibleActions: ["dismiss"])
        let run = run(status: "cancelled")
        let page = try WorkflowSteeringTestFixtures.history(items: [
            WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                     text: "Earlier caller message"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                     turnID: turnID, text: "Earlier orchestrator reply"),
            // swiftformat:disable:next trailingCommas
            WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID, outcome: "conversation")
        ])

        // when
        let presentation = WorkflowSteeringPresentation.make(
            status: status, run: run, history: page.items, observedAt: Date(timeIntervalSince1970: 1_793_836_810)
        )

        // then
        #expect(presentation.statusLine == "The run was cancelled.")
        #expect(presentation.placeholder == "Messages are off — this run was cancelled")
        #expect(presentation.action == nil)
        #expect(presentation.canDismiss, "The independent public Dismiss action remains available")
        #expect(presentation.messages.map(\.text) == ["Earlier caller message", "Earlier orchestrator reply"])
        #expect(presentation.messages.map(\.isCaller) == [true, false])
    }

    @Test func givenFinalWithoutMatchingConversationClassification_whenMakingPresentation_thenDoesNotShowAssistantText() throws {
        // given
        let status = try WorkflowSteeringTestFixtures.status(state: "awaiting_caller", held: true, eligibleActions: ["reply"])
        let run = run(status: "running")
        let page = try WorkflowSteeringTestFixtures.history(items: [
            WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "requested", action: "open", episodeID: episodeID,
                                                     text: "Keep the caller text"),
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "final_captured", episodeID: episodeID,
                                                     turnID: turnID, text: "Do not show unclassified output"),
            // swiftformat:disable:next trailingCommas
            WorkflowSteeringTestFixtures.historyItem(sequence: 4, kind: "classified", turnID: turnID, outcome: "command")
        ])

        // when
        let presentation = WorkflowSteeringPresentation.make(
            status: status, run: run, history: page.items, observedAt: Date(timeIntervalSince1970: 1_793_836_810)
        )

        // then
        #expect(presentation.messages.map(\.text) == ["Keep the caller text"])
        #expect(presentation.action == .reply)
    }

    @Test func givenPublicRetargetWithoutReply_whenAwaitingCaller_thenOffersNewConversationWithoutClaimingExpiry() throws {
        // given
        let status = try WorkflowSteeringTestFixtures.status(
            schema: 1, state: "awaiting_caller", held: true, eligibleActions: ["retarget"], createdAt: nil
        )

        // when
        let presentation = WorkflowSteeringPresentation.make(
            status: status, run: run(status: "running"), history: [], observedAt: Date(timeIntervalSince1970: 1_793_836_810)
        )

        // then
        #expect(presentation.action == .retarget)
        #expect(presentation.caption == "Your next message starts a new conversation.")
        #expect(presentation.note == nil)
        #expect(presentation.statusLine == "The run is waiting for you.")
    }

    @Test func givenSchemaOneAwaitingCaller_whenAgeCrossesThirtyMinutes_thenExpiryAppearsAtExactBoundary() throws {
        // given
        let createdAt: Double = 1_000
        let status = try WorkflowSteeringTestFixtures.status(
            schema: 1, state: "awaiting_caller", held: true, eligibleActions: ["retarget"], createdAt: createdAt
        )

        // when
        let before = WorkflowSteeringPresentation.make(
            status: status, run: run(status: "running"), history: [], observedAt: Date(timeIntervalSince1970: createdAt + 1_799)
        )
        let atBoundary = WorkflowSteeringPresentation.make(
            status: status, run: run(status: "running"), history: [], observedAt: Date(timeIntervalSince1970: createdAt + 1_800)
        )

        // then
        #expect(before.note == nil)
        #expect(before.statusLine == "The run is waiting for you.")
        #expect(atBoundary.note == "This conversation expired after 30 minutes. The run waits for you until you dismiss it or send a new message.")
        #expect(atBoundary.reason == nil)
        #expect(atBoundary.action == .retarget)
    }

    @Test(arguments: [0, 1])
    func givenPausedRootWithPositiveHold_whenProjectingApprovalPolling_thenOnlyPendingRequestPolls(pendingCount: Int) {
        // given
        let raw: [String: JSONValue] = [
            "workflow_run_id": .string(rootID), "root_workflow_run_id": .string(rootID),
            "kind": .string("workflow"), "status": .string("paused"),
            "definition": .object(["nodes": .array([])]),
            "steering_summary": .object(["hold": .bool(true)]),
            "approval_summary": .object(["pending_count": .number(Double(pendingCount))])
        ]

        // when
        let projection = WorkflowRunSidebarPresentation.build(run: raw, nodeID: WorkflowStandalone.orchestratorID, attemptID: nil)

        // then
        #expect(projection.approval.mounts == (pendingCount > 0))
        #expect(projection.approval.polls == (pendingCount > 0))
    }

    @Test func givenPendingQuestionRefusal_whenRunHasNoPublicQuestion_thenDoesNotOpenNeedsYou() throws {
        // given
        let status = try WorkflowSteeringTestFixtures.status(refusalCodes: ["steering_question_pending"])

        // when
        let presentation = WorkflowSteeringPresentation.make(
            status: status, run: run(status: "running"), history: [], observedAt: Date(timeIntervalSince1970: 1_793_836_810)
        )

        // then
        #expect(!presentation.opensNeedsYou)
        #expect(presentation.action == .open)
    }

    @Test func givenPendingQuestionRefusalAndPublicQuestion_whenMakingPresentation_thenOffersExistingNeedsYouRoute() throws {
        // given
        let status = try WorkflowSteeringTestFixtures.status(refusalCodes: ["steering_question_pending"])
        var raw = run(status: "needs_input").raw
        raw["input_decision_id"] = .string("decision-release-channel")
        raw["input_question"] = .string("Choose a release channel")
        raw["pending_inputs"] = .array([.object([
            "workflow_run_id": .string(rootID),
            "decision_id": .string("decision-release-channel"),
            "question": .string("Choose a release channel")
        ])])

        // when
        let presentation = WorkflowSteeringPresentation.make(
            status: status, run: WorkflowRunModel(raw: raw), history: [], observedAt: Date(timeIntervalSince1970: 1_793_836_810)
        )

        // then
        #expect(presentation.opensNeedsYou)
        #expect(presentation.action == nil)
        #expect(presentation.placeholder == "Answer the run's open question first.")
    }

    @Test func givenPositiveHoldSummary_whenProjectingBadgeEligibility_thenOnlyKnownRootRunsQualify() {
        // given
        let root = [
            "workflow_run_id": JSONValue.string(rootID),
            "root_workflow_run_id": JSONValue.string(rootID),
            // swiftformat:disable:next trailingCommas
            "steering_summary": .object(["hold": .bool(true)])
        ]
        var worker = root
        worker["parent_workflow_run_id"] = .string(WorkflowSteeringTestFixtures.workerID)
        var builder = root
        builder["kind"] = .string("builder")
        var unknown = root
        unknown["steering_summary"] = .object(["hold": .bool(false)])
        unknown["pending_steering_count"] = .number(0)

        // when / then
        #expect(WorkflowSteeringPresentation.hasPositiveHold(root))
        #expect(!WorkflowSteeringPresentation.hasPositiveHold(worker))
        #expect(!WorkflowSteeringPresentation.hasPositiveHold(builder))
        #expect(!WorkflowSteeringPresentation.hasPositiveHold(unknown))
    }

    @Test func givenHistoryContinuesAcrossPages_whenConsumingWithinSequenceHorizon_thenResumesFromObservedCursor() throws {
        // given
        let first = try WorkflowSteeringTestFixtures.history(
            items: [
                WorkflowSteeringTestFixtures.historyItem(sequence: 1, kind: "requested", text: "Earlier"),
                // swiftformat:disable:next trailingCommas
                WorkflowSteeringTestFixtures.historyItem(sequence: 2, kind: "final_captured", text: "Reply")
            ], nextCursor: "\(rootID):2"
        )
        let second = try WorkflowSteeringTestFixtures.history(items: [
            // swiftformat:disable:next trailingCommas
            WorkflowSteeringTestFixtures.historyItem(sequence: 3, kind: "requested", text: "Current")
        ])
        var progress = WorkflowSteeringHistoryProgress()

        // when
        let hasMore = progress.consume(first, horizon: 3)
        let continues = progress.consume(second, horizon: 3)

        // then
        #expect(hasMore)
        #expect(!continues)
        #expect(progress.rows.map(\.sequence) == [1, 2, 3])
        #expect(progress.cursor == "\(rootID):3")
        #expect(!progress.catchingUp)
        #expect(!progress.incomplete)
    }

    private func run(status: String) -> WorkflowRunModel {
        WorkflowRunModel(raw: [
            "workflow_run_id": .string(rootID),
            "root_workflow_run_id": .string(rootID),
            "status": .string(status),
            // swiftformat:disable:next trailingCommas
            "kind": .string("workflow")
        ])
    }
}
