import Foundation
@testable import MonitorCore
import Testing

struct WorkflowSteeringFixtureTests {
    private let schemaOneRoot = "000000000000000000000000000003e8"
    private let schemaTwoRoot = "000000000000000000000000000007d0"

    @Test func givenVendoredSchemaOneOrchestratorReady_whenDecodingAndOpening_thenPreservesNullAndAbsentLedgerSemantics() throws {
        let status = try #require(WorkflowSteeringStatus(data: fixture("ctl-steering-orchestrator-ready"), rootID: schemaOneRoot))
        let id = UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!
        let request = try WorkflowSteeringRequest(status: status, action: .open, text: "Open from fixture", requestID: id)
        let body = try #require(JSONSerialization.jsonObject(with: request.data) as? [String: Any])

        #expect(status.schemaVersion == 1)
        #expect(status.ledgerEpoch == nil)
        #expect(status.refusalCodes == [])
        #expect(body["ledger_epoch"] == nil)
        #expect(body["episode_id"] is NSNull)
        #expect(body["expected_steering_revision"] is NSNull)
        #expect(body["allow_fresh_context"] as? Bool == false)
    }

    @Test func givenVendoredSchemaTwoStatusAndHistory_whenDecoding_thenKeepsProducerPageIdentityAndCompleteness() throws {
        let status = try #require(WorkflowSteeringStatus(data: fixture("ctl-steering-window-status"), rootID: schemaTwoRoot))
        let page = try #require(WorkflowSteeringHistoryPage(data: fixture("ctl-steering-window-history"), rootID: schemaTwoRoot))

        #expect(status.schemaVersion == 2)
        #expect(status.ledgerEpoch == 10)
        #expect(status.sequence == 161)
        #expect(status.historyFloor == 33)
        #expect(status.refusalCodes == [])
        #expect(status.episodes.first?.createdAt == 1_793_836_800)
        #expect(page.items.count == 50)
        #expect(page.nextCursor == "000000000000000000000000000007d0:83")
        #expect(page.gap)
        #expect(page.historyIncomplete)
        #expect(page.continuationCursor(atOrBefore: 60) == "000000000000000000000000000007d0:60")
        #expect(page.continuationCursor(atOrBefore: 33) == nil)
    }

    @Test func givenVendoredAcceptedAndReplayedReceipts_whenMatchingSameExplicitRequest_thenPreservesReplayIdentity() throws {
        let status = try #require(WorkflowSteeringStatus(data: fixture("ctl-steering-orchestrator-ready"), rootID: schemaOneRoot))
        let request = try WorkflowSteeringRequest(status: status, action: .open, text: "Open from fixture",
                                                  requestID: UUID(uuidString: "00000000-0000-0000-0000-00000000000a")!)
        let accepted = try #require(WorkflowSteeringReceipt(data: fixture("ctl-steering-orchestrator-admitted"), matching: request))
        let replayed = try #require(WorkflowSteeringReceipt(data: fixture("ctl-steering-orchestrator-replayed"), matching: request))

        #expect(!accepted.replayed)
        #expect(replayed.replayed)
        #expect(accepted.requestID == request.requestID)
        #expect(replayed.requestID == request.requestID)
        #expect(accepted.sequence == replayed.sequence)
    }

    private func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "ContractsV1"))
        return try Data(contentsOf: url)
    }
}
