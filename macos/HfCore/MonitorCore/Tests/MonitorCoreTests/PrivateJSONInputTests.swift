import Foundation
@testable import MonitorCore
import Testing

struct PrivateJSONInputTests {
    @Test func givenRequestJSON_whenCreatingPrivateInput_thenPreservesBytesPermissionsAndCleansOwnedDirectory() throws {
        // given
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("steering-input-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let data = Data(#"{"text":"  exact 🦋\n--monitor  "}"#.utf8)
        let identifier = UUID()

        // when
        let input = try PrivateJSONInput(data: data, filename: "request.json", baseDirectory: base.path, identifier: identifier)
        let path = input.file

        // then
        #expect(try Data(contentsOf: path) == data)
        #expect((try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? Int) == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
        input.cleanUp()
        #expect(!FileManager.default.fileExists(atPath: path.path))
        #expect(!FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }

    @Test func givenExistingPrivateInputDirectory_whenCreatingAgain_thenDoesNotClaimOrRemoveExistingData() throws {
        // given
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("steering-input-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("harflow-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let existing = directory.appendingPathComponent("request.json")
        try Data("owned elsewhere".utf8).write(to: existing)
        let identifier = UUID(uuidString: String(directory.lastPathComponent.dropFirst("harflow-workflow-".count)))!

        // when / then
        #expect(throws: (any Error).self) {
            try PrivateJSONInput(data: Data("replacement".utf8), filename: "request.json", baseDirectory: base.path, identifier: identifier)
        }
        #expect(try Data(contentsOf: existing) == Data("owned elsewhere".utf8))
    }
}
