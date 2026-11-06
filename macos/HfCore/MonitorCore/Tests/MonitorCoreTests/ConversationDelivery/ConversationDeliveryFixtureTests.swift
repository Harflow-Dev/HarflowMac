import Foundation
@testable import MonitorCore
import Testing

// MARK: - Fixture catalogue

/// Every `ctl-conversation-*` fixture belongs to exactly one family. A new fixture that is in
/// none of them fails the catalogue test, so it cannot be added without a decision here.
enum ConvFixtureFamily {
    static let projections = [
        "empty", "queue-fifo", "queue-replayed", "now-queued", "now-claimed", "delivery-unknown", "consumed-synthetic",
        "unknown-reconciled-synthetic", "cancelled", "cancel-replayed", "promoted-now", "promotion-replayed",
        "interrupt-intent", "waiting-tool-settlement", "runtime-unknown", "closed", "bounded-window"
    ]
    static let receipts = ["send-ack", "cancel-ack", "promote-ack", "workflow-send-ack", "workflow-cancel-ack", "workflow-promote-ack"]
    static let refusals: [String: String] = [
        "refusal-cancel-issued": "already_claimed", "refusal-conversation-unknown": "conversation_unknown",
        "refusal-now-busy": "now_busy", "refusal-queue-full": "queue_full", "refusal-request-conflict": "request_conflict",
        "refusal-request-expired": "request_expired", "refusal-target-stale": "target_stale",
        "refusal-tool-interruption-unqualified": "tool_interruption_unqualified"
    ]
    static let statusReadbacks = ["task-status-available", "task-status-unavailable"]

    static var everyFile: Set<String> {
        Set((projections + receipts + Array(refusals.keys) + statusReadbacks).map(ConvFixture.file))
    }
}

// MARK: - ConversationDeliveryFixtureTests

/// Fixture-backed cases. The fixtures are synthetic recordings from the contract owner, not live
/// engine output, so these tests establish decoding only and no runtime behaviour.
struct ConversationDeliveryFixtureTests {
    @Test func givenVendoredConversationFixtures_whenCatalogued_thenAllThirtyThreeAreHandledAndNoneIsUnhandled() throws {
        // given
        let handled = ConvFixtureFamily.everyFile
        // when
        let listed = try ConvFixture.manifestNames()
        let bundled = ConvFixture.bundledNames()
        // then
        #expect(handled.count == 33)
        #expect(listed.subtracting(handled).isEmpty, "unhandled manifest fixtures: \(listed.subtracting(handled).sorted())")
        #expect(bundled.subtracting(handled).isEmpty, "unhandled bundled fixtures: \(bundled.subtracting(handled).sorted())")
        #expect(handled.subtracting(listed).isEmpty, "handled but not in manifest: \(handled.subtracting(listed).sorted())")
        #expect(handled.subtracting(bundled).isEmpty, "handled but not bundled: \(handled.subtracting(bundled).sorted())")
    }

    @Test(arguments: ConvFixtureFamily.projections + ConvFixtureFamily.receipts + Array(ConvFixtureFamily.refusals.keys)
        + ConvFixtureFamily.statusReadbacks)
    func givenFixture_whenManifestRead_thenItIsSyntheticWithoutRuntimeQualificationAndNamesTheCapability(stem: String) throws {
        // given / when
        let entry = try ConvFixture.manifestCase(stem)
        let provenance = try #require(entry["provenance"]?.objectValue)
        // then
        #expect(entry["format"]?.stringValue == "harflow.ctl")
        #expect(entry["expected_product_version"]?.stringValue == HarflowVersion.current)
        #expect(entry["required_capabilities"]?.arrayValue?.compactMap(\.stringValue) == [CtlCapability.conversationDelivery])
        #expect(provenance["synthetic"]?.boolValue == true)
        #expect(provenance["runtime_qualification"]?.boolValue == false)
    }

    @Test(arguments: ConvFixtureFamily.projections)
    func givenProjectionFixture_whenDecoded_thenExitIsZeroAndEveryWireFactSurvives(stem: String) throws {
        // given
        let raw = try ConvFixture.result(stem)
        let exit = try ConvFixture.exitCode(stem)
        // when
        let projection = try #require(ConversationDeliveryProjection(raw: raw))
        // then
        #expect(exit == 0)
        #expect(projection.raw == raw)
        #expect(projection.contract == "conversation_delivery_v1")
        #expect(projection.expected.conversationID == ConvID.conversation)
        #expect(projection.expected.headTaskID == ConvID.head)
        #expect(projection.messages.count == raw["messages"]?.arrayValue?.count)
        #expect(projection.messages.map(\.raw) == raw["messages"]?.arrayValue?.compactMap(\.objectValue))
        #expect(projection.cumulativeIssuances == raw["cumulative_issuances"]?.wireIntegerValue)
    }

    @Test(arguments: ConvFixtureFamily.projections)
    func givenProjectionFixture_whenDecodedThroughCtlClient_thenPrepareReturnsTheSameProjection(stem: String) async throws {
        // given
        let output = ConvFixture.output(stem)
        let runner = ConversationRunner { _, _ in output }
        // when
        let result = await conversationClient(runner).conversationPrepare(taskID: ConvID.head)
        // then
        #expect(try result.get() == ConvFixture.projection(stem))
        #expect(runner.commandCalls == [["conversation-prepare", "--monitor", "--json", "--", ConvID.head]])
    }

    @Test func givenEmptyFixture_whenDecoded_thenNoMessagesAndAbsentCostIsNotZero() throws {
        // given / when
        let projection = try ConvFixture.projection("empty")
        // then
        #expect(projection.messages.isEmpty)
        #expect(projection.progress?.phase == .starting)
        #expect(projection.closed == false)
        #expect(projection.runtimeFault == nil)
        #expect(projection.accounting.accountedGeneration == -1)
        #expect(projection.accounting.observedCostUSD == nil)
        #expect(projection.accounting.lastCostUSD == nil)
        #expect(projection.accounting.costBasis == "unavailable")
        #expect(projection.accounting.usageComplete == false)
    }

    @Test func givenFifoFixture_whenDecoded_thenProseIsVerbatimAndOrderFollowsSequence() throws {
        // given / when
        let projection = try ConvFixture.projection("queue-fifo")
        // then
        #expect(projection.messages.map(\.sequence) == [1, 2])
        #expect(projection.messages[0].text == "Keep  two spaces.\nFollow-up prose stays verbatim.")
        #expect(projection.messages[1].text == "Second FIFO message.")
        #expect(projection.messages.map(\.status) == [.queued, .queued])
        #expect(projection.messages.map(\.delivery) == [.queue, .queue])
        #expect(projection.messages[0].requestID == ConvID.message)
        #expect(projection.messages[0].originalTargetTaskID == ConvID.head)
        #expect(projection.messages[0].sourceGeneration == 1)
        #expect(projection.messages[0].sourceEpoch == 0)
    }

    @Test(arguments: [("queue-replayed", "queue-fifo"), ("cancel-replayed", "cancelled"), ("promotion-replayed", "promoted-now")])
    func givenReplayedFixture_whenDecoded_thenItEqualsTheOriginalProjection(replayed: String, original: String) throws {
        // given / when
        let again = try ConvFixture.projection(replayed)
        let first = try ConvFixture.projection(original)
        // then
        #expect(again == first)
    }

    @Test func givenNowQueuedFixture_whenDecoded_thenRequestedNowHasPriorityWhileStillQueued() throws {
        // given / when
        let message = try #require(ConvFixture.projection("now-queued").messages.last)
        // then
        #expect(message.requestID == ConvID.third)
        #expect(message.delivery == .now)
        #expect(message.status == .queued)
        #expect(message.destination == nil)
        #expect(message.hasNowPriority)
        #expect(!message.isPromoted)
    }

    @Test func givenNowClaimedFixture_whenDecoded_thenClaimCarriesItsDestinationAndIssuingPhase() throws {
        // given / when
        let projection = try ConvFixture.projection("now-claimed")
        let message = try #require(projection.messages.last)
        // then
        #expect(message.status == .claimed)
        #expect(message.destination?.origin == .nowDelivery)
        #expect(message.destination?.generation == 2)
        #expect(message.destination?.turnID == "00000000-0000-0000-0000-00000000000c")
        #expect(projection.progress?.phase == .issuing)
        #expect(projection.cumulativeIssuances == 1)
    }

    @Test func givenDeliveryUnknownFixture_whenDecoded_thenUnknownStatusAndPhaseAreTheLiteralUnknownValues() throws {
        // given / when
        let projection = try ConvFixture.projection("delivery-unknown")
        // then
        #expect(projection.messages.last?.status == .unknown)
        #expect(projection.messages.last?.status != .queued)
        #expect(projection.progress?.phase == .unknown)
        #expect(projection.runtimeFault == nil)
    }

    @Test func givenRuntimeUnknownFixture_whenDecoded_thenFaultIsDistinctFromUnknownMessageStatus() throws {
        // given / when
        let projection = try ConvFixture.projection("runtime-unknown")
        // then
        #expect(projection.runtimeFault?.code == "synthetic_native_unknown")
        #expect(projection.runtimeFault?.generation == 1)
        #expect(projection.runtimeFault?.turnID == ConvID.turn)
        #expect(projection.progress?.phase == .unknown)
        #expect(projection.messages.isEmpty)
    }

    @Test func givenConsumedFixture_whenDecoded_thenReceiptIsCorrelatedAndProgressIsAtBoundary() throws {
        // given / when
        let projection = try ConvFixture.projection("consumed-synthetic")
        let message = try #require(projection.messages.last)
        // then
        #expect(message.status == .consumed)
        #expect(message.receipt?.kind == "input_consumed")
        #expect(message.receipt?.generation == 2)
        #expect(projection.progress?.phase == .boundary)
        #expect(projection.progress?.nativeTerminal == "completed")
    }

    @Test func givenUnknownReconciledFixture_whenDecoded_thenConsumptionIsReceiptedWithoutASecondIssuance() throws {
        // given / when
        let projection = try ConvFixture.projection("unknown-reconciled-synthetic")
        let message = try #require(projection.messages.last)
        // then
        #expect(message.status == .consumed)
        #expect(message.receipt?.kind == "input_consumed")
        #expect(projection.cumulativeIssuances == 1)
        #expect(projection.progress?.phase == .unknown)
        #expect(projection.progress?.nativeTerminal == nil)
    }

    @Test func givenCancelledFixture_whenDecoded_thenFirstMessageIsCancelledAndOtherStaysQueued() throws {
        // given / when
        let projection = try ConvFixture.projection("cancelled")
        // then
        #expect(projection.messages.map(\.status) == [.cancelled, .queued])
        #expect(projection.messages[0].cancellationRequestID == ConvID.cancel)
        #expect(projection.messages[1].cancellationRequestID == nil)
    }

    @Test func givenPromotedFixture_whenDecoded_thenDeliveryStaysQueueAndPromotionIsRecorded() throws {
        // given / when
        let message = try #require(ConvFixture.projection("promoted-now").messages.first)
        // then
        #expect(message.delivery == .queue)
        #expect(message.status == .queued)
        #expect(message.promotionRequestID == ConvID.promote)
        #expect(message.isPromoted)
        #expect(message.hasNowPriority)
    }

    @Test func givenInterruptIntentFixture_whenDecoded_thenIntentIsKeptRawAndPhaseIsInterrupting() throws {
        // given / when
        let projection = try ConvFixture.projection("interrupt-intent")
        let message = try #require(projection.messages.last)
        // then
        #expect(projection.progress?.phase == .interrupting)
        #expect(message.delivery == .now)
        #expect(message.status == .queued)
        #expect(message.raw["interrupt_intent"]?.objectValue?["generation"]?.wireIntegerValue == 1)
    }

    @Test func givenWaitingToolFixture_whenDecoded_thenSettlementFactsAreExact() throws {
        // given / when
        let progress = try #require(ConvFixture.projection("waiting-tool-settlement").progress)
        // then
        #expect(progress.phase == .waitingTools)
        #expect(progress.nativeTerminal == "interrupted")
        #expect(progress.pendingTools == 1)
        #expect(progress.unsettledEffects == 1)
    }

    @Test func givenClosedFixture_whenDecoded_thenClosedAndPhaseClosed() throws {
        // given / when
        let projection = try ConvFixture.projection("closed")
        // then
        #expect(projection.closed)
        #expect(projection.progress?.phase == .closed)
    }

    @Test func givenBoundedWindowFixture_whenDecoded_thenCompactedWindowKeepsLaterEpochAndSequences() throws {
        // given / when
        let projection = try ConvFixture.projection("bounded-window")
        // then
        #expect(projection.messages.count == 96)
        #expect(projection.expected.ledgerEpoch == 1)
        #expect(projection.messages.first?.sequence == 2)
        #expect(projection.messages.last?.sequence == 97)
        #expect(projection.messages.filter { $0.status == .cancelled }.count == 64)
        #expect(projection.messages.filter { $0.status == .queued }.count == 32)
    }
}
