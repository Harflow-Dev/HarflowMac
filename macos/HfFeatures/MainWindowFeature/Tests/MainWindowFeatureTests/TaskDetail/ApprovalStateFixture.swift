import Foundation
import MonitorCore
import Testing

/// Reads only this repository's byte-identical vendored ctl examples; never a live engine.
func approvalStateFixture(_ name: String) throws -> [String: JSONValue] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0 ..< 6 { root.deleteLastPathComponent() }
    let path = root.appendingPathComponent("HfCore/MonitorCore/Tests/MonitorCoreTests/Resources/ContractsV1/\(name).json")
    return try #require(JSONValue.parse(Data(contentsOf: path))?.objectValue)
}

func approvalStateRequest(_ name: String) throws -> CallerApprovalRequest {
    let envelope = try approvalStateFixture(name)
    return CallerApprovalRequest(raw: try #require(envelope["result"]?.objectValue))
}

func approvalStateError(_ name: String) throws -> ToolError {
    let envelope = try approvalStateFixture(name)
    let error = try #require(envelope["error"]?.objectValue)
    return .structuredRefusal(code: error["code"]?.stringValue ?? "", message: error["message"]?.stringValue ?? "",
                              data: error["data"]?.objectValue ?? [:])
}
