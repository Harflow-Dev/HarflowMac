import Foundation
@testable import MonitorCore
import Testing

extension CtlDecodingTests {
    @Test
    func givenV9TaskDiagnostics_whenDecoded_thenStatusAndListRetainTypedEvidence() {
        let diagnostic = #"""
        {"category":"usage_limit","reason":"Quota exhausted","source":"stream:error",
         "reset_at":"2026-10-10T00:00:00Z","settlement":"needs_attention"}
        """#
        let snapshot = #"{"task_id":"limited","status":"running","failure_diagnostic":\#(diagnostic)}"#
        guard case .success(.task(let status)) = decode(#"{"v":9,"task":\#(snapshot)}"#, command: "status"),
              case .success(.tasks(let tasks)) = decode(#"{"v":9,"tasks":[\#(snapshot)]}"#) else {
            Issue.record("expected v9 status and list")
            return
        }
        #expect(status.failureDiagnostic == tasks.first?.failureDiagnostic)
        #expect(status.failureDiagnostic?.category == "usage_limit")
        #expect(status.failureDiagnostic?.reason == "Quota exhausted")
        #expect(status.failureDiagnostic?.source == "stream:error")
        #expect(status.failureDiagnostic?.resetAt?.stringValue == "2026-10-10T00:00:00Z")
        #expect(status.failureDiagnostic?.settlement == "needs_attention")
        #expect(status.status == .running, "usage-limit evidence does not imply process settlement")
    }

    @Test
    func givenOptionalOrMalformedDiagnostics_whenDecoded_thenOlderTasksRemainReadable() {
        for field in ["", #", "failure_diagnostic":null"#, #", "failure_diagnostic":{"category":7}"#] {
            guard case .success(.task(let task)) = decode(#"{"v":9,"task":{"task_id":"t"\#(field)}}"#) else {
                Issue.record("expected readable task")
                continue
            }
            #expect(task.failureDiagnostic == nil)
        }
        let data = Data(#"{"category":"future_kind","reason":"Provider explanation","source":"stderr","reset_at":1234}"#.utf8)
        let diagnostic = JSONValue.parse(data).flatMap(TaskFailureDiagnostic.init)
        #expect(diagnostic?.category == "future_kind")
        #expect(diagnostic?.resetAt?.intValue == 1234)
        #expect(diagnostic?.settlement == nil)
    }
}
