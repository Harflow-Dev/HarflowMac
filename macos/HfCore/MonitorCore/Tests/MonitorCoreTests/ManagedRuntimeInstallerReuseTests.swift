import Foundation
@testable import MonitorCore
import Testing

extension ManagedRuntimeInstallerTests {
    @Test(arguments: ["harflow-ctl", "harflow-setup", "harflow-server"])
    func givenLegacyLauncher_whenCheckingAndPreparing_thenItRequiresANewGenerationWithoutMutatingTheOld(_ tool: String) async throws {
        // given
        let home = try makeTempDir("managed-runtime-legacy-launcher")
        defer { try? FileManager.default.removeItem(at: home) }
        let (installer, downloader, runner) = makeInstaller(home: home)
        let original = try await installer.prepare()
        let path = original.generationDirectory + "/bin/" + tool
        let current = try String(contentsOfFile: path, encoding: .utf8)
        let legacy = current.replacingOccurrences(of: "raise SystemExit(main())", with: "main()")
        try Data(legacy.utf8).write(to: URL(fileURLWithPath: path))
        let requestCount = downloader.requestCount
        let callCount = runner.calls.count

        // when / then
        let availability = try await installer.checkExisting()
        #expect(availability == .requiresInstallation(installedVersion: "0.0.7", requiredVersion: "0.0.7"))
        #expect(downloader.requestCount == requestCount)
        #expect(runner.calls.count == callCount)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == legacy)

        let replacement = try await installer.prepare()
        #expect(replacement.generationDirectory != original.generationDirectory)
        #expect(downloader.requestCount > requestCount)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == legacy)
        #expect(try String(contentsOfFile: replacement.generationDirectory + "/bin/" + tool, encoding: .utf8) == current)
    }

    @Test(arguments: ["harflow-ctl", "harflow-setup", "harflow-server"])
    func givenUnreadableLauncher_whenCheckingAndPreparing_thenItRequiresANewGenerationWithoutMutatingTheOld(_ tool: String) async throws {
        // given
        let home = try makeTempDir("managed-runtime-unreadable-launcher")
        defer { try? FileManager.default.removeItem(at: home) }
        let (installer, downloader, runner) = makeInstaller(home: home)
        let original = try await installer.prepare()
        let layout = ManagedRuntimeLayout(home: home.path)
        let active = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        let path = original.generationDirectory + "/bin/" + tool
        let current = try Data(contentsOf: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: 0o111], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path) }
        let requestCount = downloader.requestCount
        let callCount = runner.calls.count

        // when / then
        let availability = try await installer.checkExisting()
        #expect(availability == .requiresInstallation(installedVersion: "0.0.7", requiredVersion: "0.0.7"))
        #expect(downloader.requestCount == requestCount)
        #expect(runner.calls.count == callCount)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == active)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o111)

        let replacement = try await installer.prepare()
        #expect(replacement.generationDirectory != original.generationDirectory)
        #expect(downloader.requestCount > requestCount)
        #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o111)
        #expect(try Data(contentsOf: URL(fileURLWithPath: replacement.generationDirectory + "/bin/" + tool)) == current)
    }

    @Test(arguments: ["None", "0", "7"])
    func givenGeneratedLaunchers_whenModuleMainReturns_thenTheirProcessExitPreservesTheResult(_ result: String) async throws {
        // given
        let home = try makeTempDir("managed runtime launcher")
        defer { try? FileManager.default.removeItem(at: home) }
        let (installer, _, _) = makeInstaller(home: home)
        let ready = try await installer.prepare()
        let directory = ready.generationDirectory
        // Run the launcher's actual Python command with only synthetic modules, never an installed engine.
        let bootstrap = "import sys, types; "
            + "modules = ['harflow_mcp.server', 'harflow_mcp.cli', 'harflow_mcp.setup_client']; "
            + "sys.modules['harflow_mcp'] = types.ModuleType('harflow_mcp'); "
            + "[sys.modules.__setitem__(name, types.ModuleType(name)) for name in modules]; "
            + "[setattr(sys.modules[name], 'main', lambda: \(result)) for name in modules]; "
            + "code = sys.argv.pop(1); exec(code)"
        let adapter = "#!/bin/sh\nset -eu\nshift 3\n"
            + "exec /usr/bin/python3 -I -B -c " + ManagedRuntimeFiles.quote(bootstrap) + " \"$@\"\n"
        try ManagedRuntimeFiles.executable(adapter, at: directory + "/python/bin/python3.13")
        let runner = ManagedRuntimeProcessRunner()

        // when / then
        for tool in ["harflow-ctl", "harflow-setup", "harflow-server"] {
            let output = await runner.run(
                executable: directory + "/bin/" + tool, arguments: [],
                environment: ["HOME": home.path, "PATH": "/usr/bin:/bin"], currentDirectory: directory, timeout: 10
            )
            switch output {
            case .success(let output):
                #expect(output.exitCode == (result == "7" ? 7 : 0))
                #expect(output.stderr.isEmpty)
            case .failure(let error):
                Issue.record("launcher execution failed: \(error)")
            }
        }
    }

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
        #expect(availability == .requiresInstallation(installedVersion: nil, requiredVersion: "0.0.7"))
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
        #expect(availability == .requiresInstallation(installedVersion: nil, requiredVersion: "0.0.7"))
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

        #expect(availability == .requiresInstallation(installedVersion: "0.0.1", requiredVersion: "0.0.7"))
        #expect(downloader.requestCount == 0)
    }
}
