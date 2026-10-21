import Foundation
@testable import MonitorCore
import Testing

extension ManagedRuntimeInstallerTests {

    @Test func givenMinimalAppPath_whenPreparingAndReusing_thenShellPathsReachReadyEnvironmentAndSetupUsesGeneration() async throws {
        // given
        let home = try makeTempDir("managed-runtime-path-discovery")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let runner = Runner(layout: ManagedRuntimeLayout(home: home.path), fixture: fixture)
        runner.loginPathOutput = "/usr/bin:/login/harness"
        runner.interactivePathOutput = "/usr/bin:/interactive/harness"
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home, runner: runner,
                                                        baseEnvironment: ["PATH": "/ambient/fake",
                                                                          "PIP_TARGET": "/outside",
                                                                          "ANTHROPIC_API_KEY": "fixture-secret"])

        // when
        let first = try await installer.prepare()
        let requestCount = downloader.requestCount
        let second = try await installer.prepare()

        // then
        #expect(first.environment == second.environment)
        #expect(first.environment["PATH"]?.split(separator: ":").map(String.init) == [
            ManagedRuntimeLayout(home: home.path).binDirectory, "/usr/bin", "/login/harness", "/interactive/harness"
        ])
        #expect(first.environment["ANTHROPIC_API_KEY"] == "fixture-secret")
        #expect(first.ctlExecutable.hasPrefix(first.generationDirectory + "/"))
        #expect(first.setupExecutable.hasPrefix(first.generationDirectory + "/"))
        #expect(FileManager.default.isExecutableFile(atPath: first.generationDirectory + "/bin/harflow-server"))
        #expect(first.environment["PATH"]?.contains("/ambient/fake") == false)
        #expect(downloader.requestCount == requestCount)
        let shellCalls = runner.calls.filter { $0.0 == "/bin/zsh" }
        #expect(shellCalls.count == 4)
        #expect(shellCalls.allSatisfy { $0.3 == home.path })
        #expect(shellCalls.allSatisfy { $0.1.contains("-l") })
        #expect(shellCalls.allSatisfy { $0.1.contains("-c") })
        #expect(runner.timeouts.filter { $0 == 8 }.count == 4)

        let setup = SetupClient(executable: first.setupExecutable, environment: first.environment, runner: runner,
                                pairedCtlExecutable: first.ctlExecutable,
                                compatibilityContext: RuntimeCompatibilityContext(expectedStateRoot: ManagedRuntimeLayout(home: home.path).stateRoot,
                                                                                   productVersion: fixture.specification.engineVersion))
        _ = await setup.perform(.install, client: "claude")
        let setupCall = runner.calls.last
        #expect(setupCall?.0 == first.setupExecutable)
        #expect(setupCall?.1 == ["--client=claude", "--json"])
        #expect(setupCall?.2["PATH"] == first.environment["PATH"])
    }

    @Test(arguments: ["native-import", "version-info"])
    func givenOldGenerationQualificationFailure_whenPreparing_thenItAcquiresAReplacementWithoutMutatingTheOldGeneration(
        failure: String
    ) async throws {
        // given
        let home = try makeTempDir("managed-runtime-qualification-replacement")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        let runner = Runner(layout: layout, fixture: fixture)
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home, runner: runner)
        let old = try await installer.prepare()
        let oldTarget = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        let oldReceipt = try Data(contentsOf: URL(fileURLWithPath: old.generationDirectory + "/completion.json"))
        if failure == "native-import" {
            runner.failingNativePaths = [old.ctlExecutable.replacingOccurrences(of: "/bin/harflow-ctl", with: "/python/bin/python3.13")]
        } else {
            runner.failingVersionInfoPaths = [old.ctlExecutable]
        }
        let requestCount = downloader.requestCount

        // when
        let replacement = try await installer.prepare()

        // then — the active old generation remains immutable while the replacement is published.
        #expect(replacement.generationDirectory != old.generationDirectory)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) != oldTarget)
        #expect(FileManager.default.fileExists(atPath: old.generationDirectory))
        #expect(try Data(contentsOf: URL(fileURLWithPath: old.generationDirectory + "/completion.json")) == oldReceipt)
        #expect(downloader.requestCount == requestCount + 4)
    }

    @Test func givenBehaviorallyBadActiveGeneration_whenReplacementAcquisitionFails_thenPointerAndReceiptRemainAndExplicitPrepareRecovers() async throws {
        // given
        let home = try makeTempDir("managed-runtime-replacement-failure")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        let runner = Runner(layout: layout, fixture: fixture)
        let downloader = Downloader(fixture: fixture)
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home, downloader: downloader, runner: runner)
        let old = try await installer.prepare()
        let oldTarget = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        let oldReceipt = try Data(contentsOf: URL(fileURLWithPath: old.generationDirectory + "/completion.json"))
        runner.failingVersionInfoPaths = [old.ctlExecutable]
        downloader.failDependency = true

        // when / then — failed replacement acquisition cannot mutate the active generation.
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == oldTarget)
        #expect(try Data(contentsOf: URL(fileURLWithPath: old.generationDirectory + "/completion.json")) == oldReceipt)

        // Explicit recovery clears the acquisition failure and can publish a replacement.
        downloader.failDependency = false
        let recovered = try await installer.prepare()
        #expect(recovered.generationDirectory != old.generationDirectory)
        let activeTarget = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        #expect(layout.runtimeRoot + "/" + activeTarget == recovered.generationDirectory)
    }
}
