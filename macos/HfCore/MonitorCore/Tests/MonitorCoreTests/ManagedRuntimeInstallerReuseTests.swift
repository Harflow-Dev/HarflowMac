import Foundation
@testable import MonitorCore
import Testing

extension ManagedRuntimeInstallerTests {
    @Test func givenQualifiedGeneration_whenCheckingExisting_thenItReusesWithoutDownloading() async throws {
        let home = try makeTempDir("managed-runtime-reuse-only")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)
        _ = try await installer.prepare()
        let requestCount = downloader.requestCount
        let availability = try await installer.checkExisting()
        guard case .ready(let ready) = availability else {
            Issue.record("expected the active generation to be reusable")
            return
        }
        #expect(ready.environment["HARFLOW_STATE_ROOT"] == ManagedRuntimeLayout(home: home.path).stateRoot)
        #expect(downloader.requestCount == requestCount)
    }

    @Test func givenNoManagedGeneration_whenCheckingExisting_thenItReportsInstallationWithoutDownloading() async throws {
        let home = try makeTempDir("managed-runtime-missing-reuse")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)
        let availability = try await installer.checkExisting()
        #expect(availability == .requiresInstallation(installedVersion: nil, requiredVersion: "0.0.5"))
        #expect(downloader.requestCount == 0)
    }

    @Test func givenMismatchedActiveGeneration_whenCheckingExisting_thenItRequiresInstallationWithoutDownloading() async throws {
        let home = try makeTempDir("managed-runtime-mismatched-reuse")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/0.0.1-foreign")
        let availability = try await installer.checkExisting()
        #expect(availability == .requiresInstallation(installedVersion: nil, requiredVersion: "0.0.5"))
        #expect(downloader.requestCount == 0)
    }

    @Test func givenQualifiedOlderGeneration_whenCheckingExisting_thenItReportsItsVersionWithoutDownloading() async throws {
        let home = try makeTempDir("managed-runtime-older-reuse")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)
        let layout = ManagedRuntimeLayout(home: home.path)
        let generation = "0.0.1-\(fixture.specification.identity)-12345678-1234-1234-1234-123456789abc"
        let directory = layout.runtimeRoot + "/generations/\(generation)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let specification = fixture.specification.identity
        let stateRoot = layout.stateRoot
        let engineHash = String(repeating: "a", count: 64)
        let receipt = "{\"schema\":1,\"specification\":\"\(specification)\","
            + "\"engineVersion\":\"0.0.1\",\"generation\":\"\(generation)\","
            + "\"stateRoot\":\"\(stateRoot)\",\"engineSHA256\":\"\(engineHash)\","
            + "\"engineYanked\":false}"
        try Data(receipt.utf8).write(to: URL(fileURLWithPath: directory + "/completion.json"))
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/\(generation)")

        let availability = try await installer.checkExisting()

        #expect(availability == .requiresInstallation(installedVersion: "0.0.1", requiredVersion: "0.0.5"))
        #expect(downloader.requestCount == 0)
    }
}
