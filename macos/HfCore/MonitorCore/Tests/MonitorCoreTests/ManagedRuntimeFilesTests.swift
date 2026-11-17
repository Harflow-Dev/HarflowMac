import Darwin
import Foundation
@testable import MonitorCore
import Testing

@Suite("Managed runtime files")
struct ManagedRuntimeFilesTests {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return root
    }

    @Test
    func givenLauncher_whenCreatedAndReplaced_thenExactBytesAndPrivateExecutableMode() throws {
        // given
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("launcher")

        // when / then
        for text in ["#!/bin/sh\necho original\n", "#!/bin/sh\nprintf 'replacement 🦊'\n"] {
            try ManagedRuntimeFiles.executable(text, at: launcher.path)
            #expect(try Data(contentsOf: launcher) == Data(text.utf8))
            let attributes = try FileManager.default.attributesOfItem(atPath: launcher.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["launcher"])
            // Ensure replacement repairs an existing executable's broader permissions.
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        }
    }

    @Test
    func givenNonregularTargets_whenWriting_thenTargetsAndSymlinkDestinationRemainUnchanged() throws {
        // given
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = root.appendingPathComponent("destination")
        try Data("original".utf8).write(to: destination)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: destination)
        let directory = root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let fifo = root.appendingPathComponent("fifo")
        #expect(mkfifo(fifo.path, S_IRUSR | S_IWUSR) == 0)

        // when / then
        for target in [link, directory, fifo] {
            #expect(throws: ManagedRuntimeFailure.self) {
                try ManagedRuntimeFiles.executable("replacement", at: target.path)
            }
        }
        #expect(try Data(contentsOf: destination) == Data("original".utf8))
        #expect(ManagedRuntimeFiles.kind(link.path) == .typeSymbolicLink)
        #expect(ManagedRuntimeFiles.kind(directory.path) == .typeDirectory)
        var information = stat()
        #expect(lstat(fifo.path, &information) == 0)
        #expect(information.st_mode & S_IFMT == S_IFIFO)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: root.path)) ==
            Set(["destination", "link", "directory", "fifo"]))
    }

    @Test
    func givenMissingParent_whenCreating_thenFailsWithoutLeavingFiles() throws {
        // given
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }

        // when
        do {
            try ManagedRuntimeFiles.executable("replacement", at: root.appendingPathComponent("missing/launcher").path)
            Issue.record("Expected exclusive sibling creation to fail")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain)
            #expect(failure.code == Int(ENOENT))
        }

        // then
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test
    func givenInvalidPublishPath_whenReplacing_thenOriginalRemainsAndSiblingIsRemoved() throws {
        // given
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let launcher = root.appendingPathComponent("launcher")
        try Data("original".utf8).write(to: launcher)
        // The independent UUID sibling fits NAME_MAX, so creation and writing
        // complete before rename rejects the overlong destination basename.
        let invalidPath = root.appendingPathComponent(String(repeating: "x", count: 256)).path

        // when
        do {
            try ManagedRuntimeFiles.executable("replacement", at: invalidPath)
            Issue.record("Expected publication to reject the overlong basename")
        } catch {
            let failure = error as NSError
            #expect(failure.domain == NSPOSIXErrorDomain)
            #expect(failure.code == Int(ENAMETOOLONG))
        }

        // then
        #expect(try Data(contentsOf: launcher) == Data("original".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["launcher"])
    }
}
