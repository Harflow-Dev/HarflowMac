import Darwin
import Foundation

// MARK: - ManagedRuntimeInstaller

/// Acquires and qualifies one immutable runtime generation. All endpoint substitution is constructor-only.
public struct ManagedRuntimeInstaller: ManagedRuntimeInstalling {
    public let layout: ManagedRuntimeLayout
    public let specification: ManagedRuntimeSpecification
    private let baseEnvironment: [String: String]
    private let runner: any ProcessRunning
    private let downloader: any ManagedRuntimeDownloading

    /// Constructs explicit managed runtime inputs without acquiring or discovering software.
    public init(layout: ManagedRuntimeLayout, specification: ManagedRuntimeSpecification,
                baseEnvironment: [String: String], runner: any ProcessRunning = ManagedRuntimeProcessRunner(),
                downloader: any ManagedRuntimeDownloading = ManagedRuntimeDownloader()) {
        self.layout = layout
        self.specification = specification
        self.baseEnvironment = baseEnvironment
        self.runner = runner
        self.downloader = downloader
    }

    /// Reuses or installs one qualified generation under the permanent cross-process lock.
    public func prepare() async throws -> ManagedRuntimeReady {
        try specification.validate()
        try Task.checkCancellation()
        try ManagedRuntimeFiles.prepareRoot(layout)
        let installationLock = try ManagedRuntimeFileLock(path: layout.runtimeRoot + "/installation.lock")
        defer { withExtendedLifetime(installationLock) {} }
        return try await prepareLocked()
    }

    private func prepareLocked() async throws -> ManagedRuntimeReady {
        try ManagedRuntimeFiles.reapStaging(layout)
        if let ready = try await reuseActive() { return ready }
        let staging = layout.runtimeRoot + "/.staging-" + UUID().uuidString
        try ManagedRuntimeFiles.privateDirectory(staging)
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let downloads = staging + "/downloads"
        try ManagedRuntimeFiles.privateDirectory(downloads)
        let environment = try installerEnvironment(staging: staging)
        let engine = try await engineRelease()
        let interpreter = try await acquire(specification.python, directory: downloads, requiredHost: nil)
        for wheel in specification.dependencies {
            _ = try await acquire(wheel, directory: downloads, requiredHost: "files.pythonhosted.org")
        }
        _ = try await acquire(engine.artifact, directory: downloads, requiredHost: "files.pythonhosted.org")
        try await command("/usr/bin/tar", ["-xzf", interpreter, "-C", staging], environment: environment, directory: staging)
        let python = staging + "/python/bin/python3.13"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            throw ManagedRuntimeFailure("The pinned interpreter archive did not contain Python 3.13.")
        }
        let dependenciesFile = staging + "/dependencies.txt"
        let engineFile = staging + "/engine.txt"
        try requirements(specification.dependencies).write(toFile: dependenciesFile, atomically: true, encoding: .utf8)
        try requirements([engine.artifact]).write(toFile: engineFile, atomically: true, encoding: .utf8)
        let flags = ["-I", "-m", "pip", "install", "--no-index", "--find-links", downloads,
                     "--require-hashes", "--only-binary=:all:", "--no-deps", "--no-user",
                     "--prefix", staging + "/python", "--no-cache-dir", "--disable-pip-version-check", "--no-input"]
        try await command(python, flags + ["-r", dependenciesFile], environment: environment, directory: staging)
        try await command(python, flags + ["-r", engineFile], environment: environment, directory: staging)
        try await validatePython(python, environment: environment, directory: staging)
        let generation = specification.engineVersion + "-" + specification.identity + "-" + UUID().uuidString
        let destination = layout.generationsDirectory + "/" + generation
        // Move only the self-contained interpreter. Never mutate an existing generation.
        try ManagedRuntimeFiles.privateDirectory(destination)
        try FileManager.default.moveItem(atPath: staging + "/python", toPath: destination + "/python")
        try createGenerationLaunchers(destination)
        let ready = ManagedRuntimeReady(generationDirectory: destination, environment: try await runtimeEnvironment())
        // Qualify after relocation, before a completion receipt or active pointer exists.
        try await qualify(ready)
        try Task.checkCancellation()
        let receipt = ManagedRuntimeReceipt(schema: 1, specification: specification.identity,
                                            engineVersion: specification.engineVersion, generation: generation,
                                            stateRoot: layout.stateRoot, engineSHA256: engine.artifact.sha256,
                                            engineYanked: engine.yanked, engineYankedReason: engine.yankedReason)
        try JSONEncoder().encode(receipt).write(to: URL(fileURLWithPath: destination + "/completion.json"), options: .atomic)
        try createStableLaunchers()
        try publish(generation)
        return ready
    }

    private func requirements(_ artifacts: [ManagedRuntimeArtifact]) -> String {
        artifacts.map { "\($0.name)==\($0.version) --hash=sha256:\($0.sha256)" }.joined(separator: "\n") + "\n"
    }

    private func acquire(_ artifact: ManagedRuntimeArtifact, directory: String, requiredHost: String?) async throws -> String {
        try Task.checkCancellation()
        let data = try await downloader.download(url: artifact.url, maximumBytes: artifact.size, requiredHost: requiredHost)
        guard data.count == artifact.size, ManagedRuntimeDigest.sha256(data) == artifact.sha256 else {
            throw ManagedRuntimeFailure("Managed runtime download failed size or SHA256 verification: " + artifact.filename)
        }
        let path = directory + "/" + artifact.filename
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        return path
    }

    private func command(_ executable: String, _ arguments: [String], environment: [String: String], directory: String) async throws {
        try Task.checkCancellation()
        let result = await runner.run(executable: executable, arguments: arguments, environment: environment,
                                      currentDirectory: directory, timeout: 300)
        try Task.checkCancellation()
        let output = try result.get()
        guard !output.timedOut, output.exitCode == 0 else {
            throw ManagedRuntimeFailure("Managed runtime preparation failed: " + (output.timedOut ? "process timed out" : String(output.stderr.suffix(1200))))
        }
    }

    private func validatePython(_ python: String, environment: [String: String], directory: String) async throws {
        try await command(python, ["-I", "-m", "pip", "check", "--no-cache-dir", "--disable-pip-version-check", "--no-input"],
                          environment: environment, directory: directory)
        let code = "import sys, importlib.metadata as m; import pydantic_core, rpds, cryptography, _cffi_backend, harflow_mcp.server; "
            + "assert sys.version.split()[0] == '\(specification.pythonVersion)'; "
            + "assert m.metadata('harflow-mcp')['Name'].lower().replace('_','-') == 'harflow-mcp'; "
            + "assert m.version('harflow-mcp') == '\(specification.engineVersion)'"
        try await command(python, ["-I", "-c", code], environment: environment, directory: directory)
    }

    private func installerEnvironment(staging: String) throws -> [String: String] {
        let home = staging + "/installer-home"
        let temporary = staging + "/installer-tmp"
        try ManagedRuntimeFiles.privateDirectory(home)
        try ManagedRuntimeFiles.privateDirectory(temporary)
        // Whitelist avoids inherited pip, Python, dynamic-loader and tool configuration entirely.
        return ["HOME": home, "TMPDIR": temporary, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "PIP_CONFIG_FILE": "/dev/null", "LANG": "en_US.UTF-8"]
    }

    private func runtimeEnvironment() async throws -> [String: String] {
        try Task.checkCancellation()
        var base = baseEnvironment
        base["HOME"] = layout.home
        let shellEnvironment = LaunchEnvironment.build(base: base, loginPath: nil, toolDirectory: nil)
        let harnessPath = await LaunchEnvironment.discoverHarnessPath(home: layout.home, environment: shellEnvironment, runner: runner)
        try Task.checkCancellation()
        var environment = LaunchEnvironment.build(base: base, loginPath: harnessPath, toolDirectory: layout.binDirectory)
        environment["HARFLOW_STATE_ROOT"] = layout.stateRoot
        return environment
    }

    private func qualify(_ ready: ManagedRuntimeReady) async throws {
        let context = RuntimeCompatibilityContext(expectedStateRoot: layout.stateRoot, productVersion: specification.engineVersion)
        let client = CtlClient(executable: ready.ctlExecutable, environment: ready.environment, runner: runner, compatibilityContext: context)
        try await client.checkCompatibility(requiring: [.ctl, .setup, .events]).get()
        let document = try await VersionInfoClient(executable: ready.ctlExecutable, environment: ready.environment,
                                                  context: context, runner: runner)
.check(requiring: [.ctl, .setup, .events])
.get()
        guard document.productVersion == specification.engineVersion else {
            throw ManagedRuntimeFailure("The managed runtime does not match the app's exact paired engine version.")
        }
    }
}

// MARK: - Acquisition metadata and activation

private extension ManagedRuntimeInstaller {
    struct EngineRelease {
        let artifact: ManagedRuntimeArtifact
        let yanked: Bool
        let yankedReason: String?
    }

    func engineRelease() async throws -> EngineRelease {
        let url = URL(string: "https://pypi.org/pypi/harflow-mcp/\(specification.engineVersion)/json")!
        let data = try await downloader.download(url: url, maximumBytes: 1 << 20, requiredHost: "pypi.org")
        guard data.count <= 1 << 20,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let info = object["info"] as? [String: Any],
              info["name"] as? String == "harflow-mcp", info["version"] as? String == specification.engineVersion,
              let files = object["urls"] as? [[String: Any]] else {
            throw ManagedRuntimeFailure("PyPI did not return the exact paired harflow-mcp release.")
        }
        let filename = "harflow_mcp-\(specification.engineVersion)-py3-none-any.whl"
        let canonical = files.filter { $0["filename"] as? String == filename }
        guard canonical.count == 1, let entry = canonical.first,
              entry["packagetype"] as? String == "bdist_wheel", entry["python_version"] as? String == "py3",
              let size = entry["size"] as? Int, let text = entry["url"] as? String, let url = URL(string: text),
              let hashes = entry["digests"] as? [String: String], let hash = hashes["sha256"],
              let yanked = entry["yanked"] as? Bool else {
            throw ManagedRuntimeFailure("The exact canonical harflow-mcp wheel is unavailable on PyPI. No alternate release will be installed.")
        }
        let artifact = ManagedRuntimeArtifact(name: "harflow-mcp", version: specification.engineVersion,
                                              filename: filename, url: url, sha256: hash, size: size)
        try artifact.validate(wheel: true)
        return EngineRelease(artifact: artifact, yanked: yanked, yankedReason: entry["yanked_reason"] as? String)
    }

    func reuseActive() async throws -> ManagedRuntimeReady? {
        guard ManagedRuntimeFiles.kind(layout.activePath) == .typeSymbolicLink else {
            if ManagedRuntimeFiles.kind(layout.activePath) != nil {
                throw ManagedRuntimeFailure("The managed active pointer is not a symbolic link.")
            }
            return nil
        }
        let target = try FileManager.default.destinationOfSymbolicLink(atPath: layout.activePath)
        let components = target.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2, components[0] == "generations", !components[1].isEmpty,
              components[1] != ".", components[1] != ".." else {
            throw ManagedRuntimeFailure("The managed active pointer has an unsafe generation path.")
        }
        let prefix = "generations/" + specification.engineVersion + "-" + specification.identity + "-"
        guard target.hasPrefix(prefix), UUID(uuidString: String(target.dropFirst(prefix.count))) != nil else { return nil }
        let directory = layout.runtimeRoot + "/" + target
        let receiptPath = directory + "/completion.json"
        guard ManagedRuntimeFiles.kind(directory) == .typeDirectory,
              ManagedRuntimeFiles.kind(directory + "/python") == .typeDirectory,
              ManagedRuntimeFiles.kind(directory + "/bin") == .typeDirectory,
              ManagedRuntimeFiles.kind(receiptPath) == .typeRegular,
              let size = try FileManager.default.attributesOfItem(atPath: receiptPath)[.size] as? Int,
              size <= 65536 else { return nil }
        let receipt = try? JSONDecoder().decode(ManagedRuntimeReceipt.self, from: Data(contentsOf: URL(fileURLWithPath: receiptPath)))
        guard let receipt, receipt.schema == 1, receipt.specification == specification.identity,
              receipt.engineVersion == specification.engineVersion, receipt.stateRoot == layout.stateRoot,
              receipt.generation == String(target.dropFirst("generations/".count)),
              receipt.engineSHA256.count == 64, receipt.engineSHA256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }),
              ManagedRuntimeFiles.kind(directory + "/python/bin/python3.13") == .typeRegular,
              ["harflow-ctl", "harflow-setup", "harflow-server"].allSatisfy({
                  ManagedRuntimeFiles.kind(directory + "/bin/" + $0) == .typeRegular
                      && FileManager.default.isExecutableFile(atPath: directory + "/bin/" + $0)
              }) else { return nil }
        let ready: ManagedRuntimeReady
        do {
            try await validatePython(directory + "/python/bin/python3.13", environment: try installerEnvironmentForReuse(), directory: directory)
            ready = ManagedRuntimeReady(generationDirectory: directory, environment: try await runtimeEnvironment())
            try await qualify(ready)
        } catch {
            if error is CancellationError { throw error }
            try Task.checkCancellation()
            // A completion receipt does not make a damaged generation reusable. Preserve it and
            // allow this attempt's one fresh acquisition; activation remains unchanged on failure.
            return nil
        }
        try Task.checkCancellation()
        try createStableLaunchers()
        return ready
    }

    func installerEnvironmentForReuse() throws -> [String: String] {
        // Reuse is read-only qualification; pip check has no cache or temporary output.
        ["HOME": "/dev/null", "TMPDIR": "/dev/null", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
         "PIP_CONFIG_FILE": "/dev/null", "LANG": "en_US.UTF-8"]
    }

    func createGenerationLaunchers(_ directory: String) throws {
        try ManagedRuntimeFiles.privateDirectory(directory + "/bin")
        for (tool, module) in [("harflow-server", "harflow_mcp.server"), ("harflow-ctl", "harflow_mcp.cli"),
                               ("harflow-setup", "harflow_mcp.setup_client")] {
            let code = "import os; "
                + "[os.environ.pop(k) for k in list(os.environ) if k.startswith(('HARFLOW_', 'PB_'))]; "
                + "os.environ['HARFLOW_STATE_ROOT']=\(pythonLiteral(layout.stateRoot)); "
                + "os.environ['HARFLOW_OPEN_MONITOR']='0'; "
                + "os.environ['PATH']=\(pythonLiteral(layout.binDirectory))+':'+os.environ.get('PATH','/usr/bin:/bin'); "
                + "from \(module) import main; main()"
            let text = "#!/bin/sh\nset -eu\nROOT=$(CDPATH= cd -P -- \"$(/usr/bin/dirname -- \"$0\")/..\" && pwd)\n"
                + "exec \"$ROOT/python/bin/python3.13\" -I -B -c " + ManagedRuntimeFiles.quote(code) + " \"$@\"\n"
            try ManagedRuntimeFiles.executable(text, at: directory + "/bin/" + tool)
        }
    }

    func pythonLiteral(_ value: String) -> String {
        // JSON strings are also Python string literals for these path values, without control characters.
        let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "''"
    }

    func createStableLaunchers() throws {
        for tool in ["harflow-server", "harflow-ctl", "harflow-setup"] {
            let text = "#!/bin/sh\nset -eu\nROOT=$(CDPATH= cd -P -- \"$(/usr/bin/dirname -- \"$0\")/..\" && pwd)\n"
                + "GEN=$(/usr/bin/readlink \"$ROOT/active\")\n"
                + "case \"$GEN\" in generations/*) ;; *) exit 70 ;; esac\n"
                + "case \"$GEN\" in *..*|*/*/*) exit 70 ;; esac\n"
                + "exec \"$ROOT/$GEN/bin/\(tool)\" \"$@\"\n"
            try ManagedRuntimeFiles.executable(text, at: layout.binDirectory + "/" + tool)
        }
    }

    func publish(_ generation: String) throws {
        let temporary = layout.runtimeRoot + "/.active-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: temporary) }
        try FileManager.default.createSymbolicLink(atPath: temporary, withDestinationPath: "generations/" + generation)
        guard rename(temporary, layout.activePath) == 0 else {
            throw ManagedRuntimeFailure("Cannot atomically activate the qualified managed runtime.")
        }
    }
}
