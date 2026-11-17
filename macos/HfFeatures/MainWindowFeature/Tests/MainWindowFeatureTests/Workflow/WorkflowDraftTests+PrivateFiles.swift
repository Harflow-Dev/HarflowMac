import Foundation
@testable import MainWindowFeature
import MonitorCore
import Testing

// MARK: - Workflow draft private replacement

extension WorkflowDraftTests {
    @Test func givenExistingDraft_whenReplaced_thenExactBytesAndPrivateModesRemainWithoutSiblingTemps() throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowDraftStore(directory: directory)
        try store.save(["name": .string("Before")], key: "new")
        let originalFiles = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let file = try #require(originalFiles.first)
        let replacement: [String: JSONValue] = ["name": .string("After"), "instructions": .string("Private\nexact whitespace  ")]
        // when
        try store.save(replacement, key: "new")
        // then
        #expect(try store.load(key: "new") == replacement)
        #expect(try Data(contentsOf: file) == Data(JSONValue.object(replacement).rendered().utf8))
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        #expect(files == originalFiles)
        #expect((try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func givenRenameRefusal_whenReplacingDraft_thenOwnedTemporaryIsRemovedAndOtherContentSurvives() throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowDraftStore(directory: directory)
        try store.save(["name": .string("Preserved")], key: "new")
        let target = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let originalBytes = try Data(contentsOf: target)
        let preserved = directory.appendingPathComponent("original-draft")
        try FileManager.default.moveItem(at: target, to: preserved)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let marker = target.appendingPathComponent("foreign-marker")
        try Data("do not remove".utf8).write(to: marker)
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        // when / then: replacing a nonempty directory is a real rename failure.
        #expect(throws: Error.self) { try store.save(["name": .string("Rejected")], key: "new") }
        #expect(try Data(contentsOf: preserved) == originalBytes)
        #expect(try Data(contentsOf: marker) == Data("do not remove".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == before)
    }

    @Test func givenUnwritableDraftDirectory_whenSaving_thenOriginalDraftRemainsUnchanged() throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = WorkflowDraftStore(directory: directory)
        let original: [String: JSONValue] = ["name": .string("Preserved")]
        try store.save(original, key: "new")
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        // when / then
        #expect(throws: Error.self) { try store.save(["name": .string("Rejected")], key: "new") }
        #expect(try store.load(key: "new") == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == before)
    }

    @Test func givenSymlinkAtDraftTarget_whenReplacing_thenForeignFileIsUntouchedAndLocalNameBecomesPrivateFile() throws {
        // given
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WorkflowDraftStore(directory: directory)
        try store.save(["name": .string("Before")], key: "new")
        let target = try #require(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let foreign = directory.appendingPathComponent("foreign")
        try Data("foreign contents".utf8).write(to: foreign)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: foreign)
        // when
        try store.save(["name": .string("Replacement")], key: "new")
        // then
        #expect(try Data(contentsOf: foreign) == Data("foreign contents".utf8))
        #expect(try store.load(key: "new") == ["name": .string("Replacement")])
        #expect(try FileManager.default.attributesOfItem(atPath: target.path)[.type] as? FileAttributeType == .typeRegular)
    }
}
