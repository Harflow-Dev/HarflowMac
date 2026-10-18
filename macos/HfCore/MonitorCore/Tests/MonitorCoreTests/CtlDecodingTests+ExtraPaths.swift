import Foundation
@testable import MonitorCore
import Testing

extension CtlDecodingTests {
    @Test
    func givenV10BoundedPathMetadata_whenDecoded_thenStatusRetainsAuthorityAndBackendsRemainReadable() {
        // given / when
        let document = #"""
        {"v":10,"task":{"task_id":"bounded",
        "extra_writable_paths":[{"path":"/outside","kind":"directory"}],
        "extra_path_certification":"cert",
        "resume_command":null,
        "enforcement":{"extra_writable_paths":[{"path":"/outside","kind":"directory"}],
        "extra_path_certification":"cert"}}}
        """#
        guard case .success(.task(let task)) = decode(document, command: "status") else { Issue.record("expected v10 task"); return }
        // then
        #expect(task.raw["extra_path_certification"]?.stringValue == "cert")
        #expect(task.raw["extra_writable_paths"]?.arrayValue?.first?["path"]?.stringValue == "/outside")
        #expect(task.raw["enforcement"]?["extra_path_certification"]?.stringValue == "cert")
        #expect(task.resumeCommand == nil)
        let backendDocument = #"""
        {"v":10,"backends":[{"backend":"codex","binary":"codex","installed":true,
        "capabilities":{"extra_writable_paths":{"supported":true,"certification":"cert"}}}]}
        """#
        guard case .success(.backends(let backends)) = decode(backendDocument, command: "backends") else { Issue.record("expected v10 backends"); return }
        #expect(backends.first?.backend == "codex")
        #expect(backends.first?.installed == true)
    }

}
