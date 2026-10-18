import Foundation
@testable import MonitorCore
import Testing

// MARK: - Workflow contract decoding

extension CtlDecodingTests {
    @Test
    func givenV8PermissionPreview_whenDecoded_thenOwnerContractAndHashAreRetained() {
        // given
        let document = #"{"v":8,"result":{"preview_hash":"launch-hash","owner_contracts":{"version":"native_owner_contract_v1","owners":{}}}}"#
        // when
        guard case .success(.result(let result)) = decode(document, command: "workflow-preview") else {
            Issue.record("v8 preview should decode")
            return
        }
        // then
        #expect(result["preview_hash"]?.stringValue == "launch-hash")
        #expect(result["owner_contracts"]?["version"]?.stringValue == "native_owner_contract_v1")
    }

    @Test(arguments: [7, 8])
    func givenHistoricalRunWithoutOwnerContracts_whenDecoded_thenAbsenceIsPreserved(version: Int) {
        // given
        let document = "{\"v\":\(version),\"result\":{\"workflow_run_id\":\"historical\",\"status\":\"completed\"}}"
        // when
        guard case .success(.result(let result)) = decode(document, command: "workflow-status") else {
            Issue.record("historical result should decode")
            return
        }
        // then
        #expect(result["workflow_run_id"]?.stringValue == "historical")
        #expect(result["owner_contracts"] == nil)
    }

}
