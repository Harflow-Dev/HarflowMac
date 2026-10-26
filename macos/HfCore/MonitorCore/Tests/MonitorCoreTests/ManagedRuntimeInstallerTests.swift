import CryptoKit
import Foundation
@testable import MonitorCore
import Testing

@Suite("Managed runtime installer", .serialized, .timeLimit(.minutes(1)))
struct ManagedRuntimeInstallerTests {
    struct Fixture: Sendable {
        let specification: ManagedRuntimeSpecification
        let python: Data
        let dependency: Data
        let engine: Data
        let metadata: Data

        init(yanked: Bool = false, canonicalFile: Bool = true) {
            self.python = Data("python archive".utf8)
            self.dependency = Data("dependency wheel".utf8)
            self.engine = Data("engine wheel".utf8)
            let pythonArtifact = ManagedRuntimeArtifact(
                name: "python", version: "3.13.16", filename: "cpython.tar.gz",
                url: URL(string: "https://example.com/cpython.tar.gz")!,
                sha256: Self.digest(python), size: python.count
            )
            let dependencyArtifact = ManagedRuntimeArtifact(
                name: "dependency", version: "1.0.0", filename: "dependency-1.0.0-py3-none-any.whl",
                url: URL(string: "https://files.pythonhosted.org/packages/dependency-1.0.0-py3-none-any.whl")!,
                sha256: Self.digest(dependency), size: dependency.count
            )
            self.specification = ManagedRuntimeSpecification(
                engineVersion: "0.0.3", pythonVersion: "3.13.16", python: pythonArtifact,
                dependencies: [dependencyArtifact], provenance: "test fixture"
            )
            let engineURL = "https://files.pythonhosted.org/packages/harflow_mcp-0.0.3-py3-none-any.whl"
            let file: [String: Any] = [
                "filename": "harflow_mcp-0.0.3-py3-none-any.whl",
                "packagetype": "bdist_wheel", "python_version": "py3", "size": engine.count,
                "url": engineURL, "digests": ["sha256": Self.digest(engine)],
                "yanked": yanked, "yanked_reason": yanked ? "fixture reason" : NSNull()
            ]
            let urls = canonicalFile ? [file] : [[String: Any](uniqueKeysWithValues: file.filter { $0.key != "filename" }.map { ($0.key, $0.value) })]
            self.metadata = (try? JSONSerialization.data(withJSONObject: [
                "info": ["name": "harflow-mcp", "version": "0.0.3"], "urls": urls
            ])) ?? Data()
        }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    final class Downloader: ManagedRuntimeDownloading, @unchecked Sendable {
        let fixture: Fixture
        let lock = NSLock()
        private(set) var requests: [(URL, String?)] = []
        var corruptEngine = false
        var metadataOverride: Data?
        var failDependency = false
        var blockDownloads = false

        var requestCount: Int { lock.withLock { requests.count } }

        init(fixture: Fixture) { self.fixture = fixture }

        private func record(_ request: (URL, String?)) {
            lock.lock()
            requests.append(request)
            lock.unlock()
        }

        func download(url: URL, maximumBytes _: Int, requiredHost: String?) async throws -> Data {
            record((url, requiredHost))
            if blockDownloads { try await Task.sleep(for: .seconds(60)) }
            if url.host == "pypi.org" { return metadataOverride ?? fixture.metadata }
            switch url.lastPathComponent {
            case fixture.specification.python.filename: return fixture.python
            case fixture.specification.dependencies[0].filename:
                if failDependency { throw ManagedRuntimeFailure("fixture dependency failure") }
                return fixture.dependency
            default: return corruptEngine ? Data("wrong".utf8) : fixture.engine
            }
        }
    }

    final class Runner: ProcessRunning, @unchecked Sendable {
        let layout: ManagedRuntimeLayout
        let fixture: Fixture
        let lock = NSLock()
        private(set) var calls: [(String, [String], [String: String], String?)] = []
        private(set) var timeouts: [Double] = []
        var mismatchedVersionInfo = false
        var nativeFailure = false
        var failingVersionInfoPaths: Set<String> = []
        var failingNativePaths: Set<String> = []
        var loginPathOutput: String?
        var interactivePathOutput: String?

        init(layout: ManagedRuntimeLayout, fixture: Fixture) {
            self.layout = layout
            self.fixture = fixture
        }

        private func record(_ call: (String, [String], [String: String], String?)) {
            lock.lock()
            calls.append(call)
            lock.unlock()
        }

        private func recordTimeout(_ timeout: Double) {
            lock.lock()
            timeouts.append(timeout)
            lock.unlock()
        }

        func run(
            executable: String, arguments: [String], environment: [String: String], currentDirectory: String?, timeout: Double
        ) async -> Result<ProcessOutput, ToolError> {
            record((executable, arguments, environment, currentDirectory))
            recordTimeout(timeout)
            if executable == "/bin/zsh" {
                let path = arguments.contains("-i") ? interactivePathOutput : loginPathOutput
                return .success(ProcessOutput(exitCode: 0, stdout: Data((path ?? "").utf8), stderr: ""))
            }
            if executable == "/usr/bin/tar", let index = arguments.firstIndex(of: "-C"), index + 1 < arguments.count {
                let staging = arguments[index + 1]
                let python = staging + "/python/bin/python3.13"
                try? FileManager.default.createDirectory(atPath: staging + "/python/bin", withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: python, contents: Data("fake python".utf8), attributes: [.posixPermissions: 0o700])
            }
            if arguments == ["version-info", "--json"] {
                if failingVersionInfoPaths.contains(executable) {
                    return .failure(.launchFailed(tool: executable, detail: "fixture version-info failure"))
                }
                let root = environment["HARFLOW_STATE_ROOT"] ?? layout.stateRoot
                let version = mismatchedVersionInfo ? "9.9.9" : fixture.specification.engineVersion
                let document = "{" +
                    "\"product\":\"harflow\",\"format\":\"harflow.version-info\",\"v\":1," +
                    "\"product_version\":\"\(version)\",\"component\":\"engine\",\"state_root\":\"\(root)\"," +
                    "\"contracts\":{\"ctl\":{\"format\":\"harflow.ctl\",\"v\":1}," +
                    "\"setup\":{\"format\":\"harflow.setup\",\"v\":1},\"events\":{\"format\":\"harflow.event\",\"v\":1}}," +
                    "\"capabilities\":[\"ctl.v1\",\"setup.v1\",\"events.v1\"],\"os\":\"darwin\",\"architecture\":\"arm64\"}"
                return .success(ProcessOutput(exitCode: 0, stdout: Data(document.utf8), stderr: ""))
            }
            if nativeFailure || failingNativePaths.contains(executable), arguments.contains("-c") {
                return .failure(.launchFailed(tool: executable, detail: "fixture native import failure"))
            }
            return .success(ProcessOutput(exitCode: 0, stdout: Data(), stderr: ""))
        }
    }

    func makeInstaller(
        fixture: Fixture = Fixture(),
        home: URL,
        downloader: Downloader? = nil,
        runner: Runner? = nil,
        baseEnvironment: [String: String] = ["PATH": "/usr/bin:/bin", "PIP_TARGET": "/outside",
                                              "ANTHROPIC_API_KEY": "fixture-secret"]
    ) -> (ManagedRuntimeInstaller, Downloader, Runner) {
        let layout = ManagedRuntimeLayout(home: home.path)
        let selectedDownloader = downloader ?? Downloader(fixture: fixture)
        let selectedRunner = runner ?? Runner(layout: layout, fixture: fixture)
        let installer = ManagedRuntimeInstaller(layout: layout, specification: fixture.specification,
                                                baseEnvironment: baseEnvironment,
                                                runner: selectedRunner, downloader: selectedDownloader)
        return (installer, selectedDownloader, selectedRunner)
    }

    @Test func givenQualifiedFixture_whenPreparingTwice_thenSecondPreparationReusesActiveGenerationWithoutNetwork() async throws {
        // given
        let home = try makeTempDir("managed-runtime-reuse")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)

        // when
        let first = try await installer.prepare()
        let requestCount = downloader.requests.count
        let second = try await installer.prepare()

        // then
        #expect(first.generationDirectory == second.generationDirectory)
        #expect(downloader.requests.count == requestCount)
    }

    @Test(arguments: ["specification", "stateRoot", "engineSHA256"])
    func givenStaleCompletionReceipt_whenPreparing_thenItRejectsReuseAndCreatesANewGeneration(
        invalidField: String
    ) async throws {
        // given
        let home = try makeTempDir("managed-runtime-stale-receipt")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, downloader, _) = makeInstaller(fixture: fixture, home: home)
        let first = try await installer.prepare()
        let receiptURL = URL(fileURLWithPath: first.generationDirectory + "/completion.json")
        guard var receipt = try JSONSerialization.jsonObject(with: Data(contentsOf: receiptURL)) as? [String: Any] else {
            Issue.record("Expected a JSON completion receipt")
            return
        }
        switch invalidField {
        case "specification": receipt["specification"] = "stale-specification"
        case "stateRoot": receipt["stateRoot"] = "/foreign/.harflow"
        case "engineSHA256": receipt["engineSHA256"] = "malformed"
        default: Issue.record("Unexpected receipt field fixture")
        }
        try JSONSerialization.data(withJSONObject: receipt).write(to: receiptURL, options: .atomic)
        let requestCount = downloader.requestCount

        // when
        let second = try await installer.prepare()

        // then
        #expect(second.generationDirectory != first.generationDirectory)
        #expect(downloader.requestCount > requestCount)
    }

    @Test func givenForeignActiveGeneration_whenPreparing_thenItDoesNotAdoptIt() async throws {
        // given
        let home = try makeTempDir("managed-runtime-foreign-generation")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot + "/generations/foreign", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/foreign")
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home)

        // when
        let ready = try await installer.prepare()

        // then
        #expect(ready.generationDirectory != layout.runtimeRoot + "/generations/foreign")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) != "generations/foreign")
    }

    @Test func givenCrashStagingAndSymlinkEntries_whenPreparing_thenItReapsOnlyManagedStagingDirectories() async throws {
        // given
        let home = try makeTempDir("managed-runtime-staging-reap")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot, withIntermediateDirectories: true)
        let generations = layout.runtimeRoot + "/generations"
        try FileManager.default.createDirectory(atPath: generations + "/old", withIntermediateDirectories: true)
        let stale = layout.runtimeRoot + "/.staging-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: stale, withIntermediateDirectories: true)
        let external = home.deletingLastPathComponent().appendingPathComponent("managed-runtime-staging-target-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let link = layout.runtimeRoot + "/.staging-\(UUID().uuidString)"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: external.path)
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home)

        // when
        _ = try await installer.prepare()

        // then
        #expect(!FileManager.default.fileExists(atPath: stale))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == external.path)
        #expect(FileManager.default.fileExists(atPath: external.path))
        #expect(FileManager.default.fileExists(atPath: generations + "/old"))
    }

    @Test func givenAnotherProcessOwnsThePermanentLock_whenPreparing_thenNoDownloadOrProcessRuns() async throws {
        // given
        let home = try makeTempDir("managed-runtime-lock")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot, withIntermediateDirectories: true)
        let held = try ManagedRuntimeFileLock(path: layout.runtimeRoot + "/installation.lock")
        let (installer, downloader, runner) = makeInstaller(fixture: fixture, home: home)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await prepareWhileHolding(held, installer: installer)
        }
        #expect(downloader.requests.isEmpty)
        #expect(runner.calls.isEmpty)
    }

    @Test func givenQualifiedGeneration_whenReadingStableLauncher_thenItFollowsActivePointerAndKeepsSelectedRoot() async throws {
        // given
        let home = try makeTempDir("managed-runtime-launcher")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home)

        // when
        let ready = try await installer.prepare()
        let layout = ManagedRuntimeLayout(home: home.path)
        let launcher = try String(contentsOfFile: layout.binDirectory + "/harflow-ctl", encoding: .utf8)

        // then
        #expect(ready.environment["HARFLOW_STATE_ROOT"] == layout.stateRoot)
        #expect(ready.environment["ANTHROPIC_API_KEY"] == "fixture-secret")
        let activeTarget = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        #expect(layout.runtimeRoot + "/" + activeTarget == ready.generationDirectory)
        #expect(launcher.contains("readlink \"$ROOT/active\""))
        let generationLauncher = try String(contentsOfFile: ready.ctlExecutable, encoding: .utf8)
        #expect(generationLauncher.contains("HARFLOW_STATE_ROOT"))
        #expect(generationLauncher.contains("python/bin/python3.13"))
        #expect(!launcher.contains("uv"))
        #expect(!launcher.contains("Homebrew"))
        #expect(!launcher.contains("/Applications/"))
    }

    @Test func givenHostilePipEnvironment_whenPreparing_thenInstallerUsesPrivateConfigurationAndNoOutsideTarget() async throws {
        // given
        let home = try makeTempDir("managed-runtime-pip")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home)

        // when
        _ = try await installer.prepare()

        // then
        let pipCalls = runner.calls.filter { $0.1.contains("pip") }
        #expect(!pipCalls.isEmpty)
        #expect(pipCalls.allSatisfy { call in
            call.2["PIP_CONFIG_FILE"] == "/dev/null" && call.2["PIP_TARGET"] == nil &&
                call.2["PIP_PREFIX"] == nil && call.2["PIP_USER"] == nil &&
                (call.2["HOME"]?.hasPrefix(home.path) == true) &&
                (call.2["TMPDIR"]?.hasPrefix(home.path) == true) &&
                call.1.contains("--no-cache-dir") && call.1.contains("--disable-pip-version-check") &&
                call.1.contains("--no-input")
        })
        let installCalls = pipCalls.filter { $0.1.contains("install") }
        #expect(installCalls.count == 2)
        #expect(installCalls.allSatisfy { call in
            guard let prefixIndex = call.1.firstIndex(of: "--prefix"), prefixIndex + 1 < call.1.endIndex else {
                return false
            }
            let prefix = call.1[call.1.index(after: prefixIndex)]
            return call.1.contains("--no-index") && call.1.contains("--require-hashes") &&
                call.1.contains("--only-binary=:all:") && call.1.contains("--no-deps") &&
                call.1.contains("--no-user") && call.1.contains("--disable-pip-version-check") &&
                prefix.hasPrefix(ManagedRuntimeLayout(home: home.path).runtimeRoot + "/.staging-") &&
                prefix.hasSuffix("/python")
        })
    }

    @Test func givenMissingCanonicalWheel_whenPreparing_thenItFailsBeforeInterpreterExecution() async throws {
        // given
        let home = try makeTempDir("managed-runtime-missing-wheel")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture(canonicalFile: false)
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenWrongReleaseMetadata_whenPreparing_thenItFailsBeforeInterpreterExecution() async throws {
        // given
        let home = try makeTempDir("managed-runtime-wrong-release")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let downloader = Downloader(fixture: fixture)
        downloader.metadataOverride = try JSONSerialization.data(withJSONObject: [
            "info": ["name": "harflow-mcp", "version": "9.9.9"], "urls": []
        ])
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home, downloader: downloader)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenEngineHashMismatch_whenPreparing_thenItFailsBeforeOfflinePipInstallation() async throws {
        // given
        let home = try makeTempDir("managed-runtime-hash-mismatch")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let downloader = Downloader(fixture: fixture)
        downloader.corruptEngine = true
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home, downloader: downloader)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenEngineSizeMismatchWithMatchingDigest_whenPreparing_thenItFailsBeforeProcessOrActivation() async throws {
        // given
        let home = try makeTempDir("managed-runtime-size-mismatch")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot + "/generations/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/old")
        let downloader = Downloader(fixture: fixture)
        guard var metadata = try JSONSerialization.jsonObject(with: fixture.metadata) as? [String: Any],
              var urls = metadata["urls"] as? [[String: Any]] else {
            Issue.record("Expected fixture metadata URLs")
            return
        }
        urls[0]["size"] = fixture.engine.count + 1
        metadata["urls"] = urls
        downloader.metadataOverride = try JSONSerialization.data(withJSONObject: metadata)
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home, downloader: downloader)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == "generations/old")
    }

    @Test func givenDependencyDownloadFailure_whenPreparing_thenItFailsBeforeInterpreterExecution() async throws {
        // given
        let home = try makeTempDir("managed-runtime-missing-dependency")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let downloader = Downloader(fixture: fixture)
        downloader.failDependency = true
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home, downloader: downloader)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenNativeQualificationFailure_whenPreparing_thenPriorActivePointerRemains() async throws {
        // given
        let home = try makeTempDir("managed-runtime-native-failure")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot + "/generations/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/old")
        let runner = Runner(layout: layout, fixture: fixture)
        runner.nativeFailure = true
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home, runner: runner)

        // when / then
        do {
            _ = try await installer.prepare()
            Issue.record("Expected native qualification failure")
        } catch let error as ToolError {
            guard case let .launchFailed(_, detail) = error else {
                Issue.record("Expected native launch failure, got \(error)")
                return
            }
            #expect(detail == "fixture native import failure")
        } catch {
            Issue.record("Expected ToolError native failure, got \(error)")
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == "generations/old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.runtimeRoot).filter { $0.hasPrefix(".staging-") }.isEmpty)
    }

    @Test func givenPreparationCancellationDuringDownload_whenPreparing_thenStagingAndPriorActiveRemain() async throws {
        // given
        let home = try makeTempDir("managed-runtime-cancel")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot + "/generations/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/old")
        let downloader = Downloader(fixture: fixture)
        downloader.blockDownloads = true
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home, downloader: downloader)
        let task = Task { try await installer.prepare() }
        #expect(await waitUntil { downloader.requestCount > 0 })

        // when
        task.cancel()
        let outcome = await task.result

        // then
        guard case .failure = outcome else {
            Issue.record("Expected cancellation to propagate from preparation")
            return
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == "generations/old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: layout.runtimeRoot).filter { $0.hasPrefix(".staging-") }.isEmpty)
    }

    @Test func givenYankedExactWheel_whenPreparing_thenExactVersionRemainsEligible() async throws {
        // given
        let home = try makeTempDir("managed-runtime-yanked")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture(yanked: true)
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home)

        // when
        let ready = try await installer.prepare()

        // then
        let receiptData = try Data(contentsOf: URL(fileURLWithPath: ready.generationDirectory + "/completion.json"))
        let receipt = try JSONDecoder().decode(ManagedRuntimeReceipt.self, from: receiptData)
        #expect(receipt.engineYanked)
        #expect(receipt.engineYankedReason == "fixture reason")
    }

    @Test func givenForeignEngineWheelHost_whenPreparing_thenItFailsBeforeInterpreterExecution() async throws {
        // given
        let home = try makeTempDir("managed-runtime-foreign-host")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let downloader = Downloader(fixture: fixture)
        downloader.metadataOverride = try JSONSerialization.data(withJSONObject: [
            "info": ["name": "harflow-mcp", "version": "0.0.3"], "urls": [[
                "filename": "harflow_mcp-0.0.3-py3-none-any.whl", "packagetype": "bdist_wheel",
                "python_version": "py3", "size": fixture.engine.count,
                "url": "https://example.com/harflow_mcp-0.0.3-py3-none-any.whl",
                "digests": ["sha256": Fixture.digest(fixture.engine)], "yanked": false
            ]]
        ])
        let (installer, _, runner) = makeInstaller(fixture: fixture, home: home, downloader: downloader)

        // when / then
        await #expect(throws: ManagedRuntimeFailure.self) {
            try await installer.prepare()
        }
        #expect(runner.calls.isEmpty)
    }

    @Test func givenActivationQualificationFails_whenPreparing_thenPriorActivePointerRemains() async throws {
        // given
        let home = try makeTempDir("managed-runtime-preserve")
        defer { try? FileManager.default.removeItem(at: home) }
        let fixture = Fixture()
        let layout = ManagedRuntimeLayout(home: home.path)
        try FileManager.default.createDirectory(atPath: layout.runtimeRoot + "/generations/old", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: layout.activePath, withDestinationPath: "generations/old")
        let runner = Runner(layout: layout, fixture: fixture)
        runner.mismatchedVersionInfo = true
        let (installer, _, _) = makeInstaller(fixture: fixture, home: home, runner: runner)

        // when / then
        do {
            _ = try await installer.prepare()
            Issue.record("Expected incompatible runtime refusal")
        } catch let error as ToolError {
            guard case let .refused(code, message) = error else {
                Issue.record("Expected incompatible runtime refusal, got \(error)")
                return
            }
            #expect(code == "incompatible_runtime")
            #expect(message == "Incompatible Harflow runtime: product major/minor release line differs from 0.0.3")
        } catch {
            Issue.record("Expected ToolError refusal, got \(error)")
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath) == "generations/old")
    }
}

private func prepareWhileHolding(
    _ lock: ManagedRuntimeFileLock, installer: ManagedRuntimeInstaller
) async throws -> ManagedRuntimeReady {
    defer { withExtendedLifetime(lock) {} }
    return try await installer.prepare()
}
