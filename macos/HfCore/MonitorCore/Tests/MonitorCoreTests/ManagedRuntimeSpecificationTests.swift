import Foundation
@testable import MonitorCore
import Testing

@Suite("Managed runtime specification")
struct ManagedRuntimeSpecificationTests {
    private func packagedSpecificationData() throws -> Data {
        try JSONEncoder().encode(ManagedRuntimeSpecification.bundled())
    }

    private func packagedFixture() throws -> (bundleURL: URL, resourceURL: URL) {
        let root = try makeTempDir("managed-runtime-app")
        let appURL = root.appendingPathComponent("Harflow.app", isDirectory: true)
        let resourceURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        let bundleURL = resourceURL.appendingPathComponent("MonitorCore_MonitorCore.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        try packagedSpecificationData().write(to: bundleURL.appendingPathComponent("ManagedRuntime.json"))
        return (appURL, resourceURL)
    }

    private func artifact(
        name: String = "dependency",
        version: String = "1.0.0",
        filename: String = "dependency-1.0.0-py3-none-any.whl",
        url: String = "https://files.pythonhosted.org/packages/dependency.whl",
        hash: String = String(repeating: "a", count: 64),
        size: Int = 1
    ) -> ManagedRuntimeArtifact {
        ManagedRuntimeArtifact(name: name, version: version, filename: filename,
                               url: URL(string: url)!, sha256: hash, size: size)
    }

    @Test func givenBundledSpecification_whenLoaded_thenItPinsThePairedEngineAndAllDependencies() throws {
        // given / when
        let specification = try ManagedRuntimeSpecification.bundled()

        // then
        #expect(specification.schema == 1)
        #expect(specification.engineVersion == "0.0.1")
        #expect(specification.pythonVersion == "3.13.16")
        #expect(specification.python.version == specification.pythonVersion)
        #expect(specification.dependencies.count == 29)
        #expect(specification.dependencies.allSatisfy { $0.url.host == "files.pythonhosted.org" })
        #expect(specification.dependencies.allSatisfy { $0.filename.hasSuffix(".whl") })
        try specification.validate()
    }

    @Test func givenPackagedAppResources_whenLoaded_thenItUsesTheAuthoritativeResourceBundle() throws {
        let fixture = try packagedFixture()
        let specification = try ManagedRuntimeSpecification.bundled(
            bundleURL: fixture.bundleURL,
            resourceURL: fixture.resourceURL
        )
        #expect(specification.engineVersion == "0.0.1")
        #expect(specification.pythonVersion == "3.13.16")
    }

    @Test(arguments: ["missing", "misplaced", "corrupt"])
    func givenInvalidPackagedResource_whenLoaded_thenItFailsWithoutSwiftPMFallback(_ caseName: String) throws {
        let root = try makeTempDir("managed-runtime-invalid-app")
        let appURL = root.appendingPathComponent("Harflow.app", isDirectory: true)
        let resourceURL = appURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceURL, withIntermediateDirectories: true)
        switch caseName {
        case "misplaced":
            try packagedSpecificationData().write(to: resourceURL.appendingPathComponent("ManagedRuntime.json"))
        case "corrupt":
            let bundleURL = resourceURL.appendingPathComponent("MonitorCore_MonitorCore.bundle", isDirectory: true)
            try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(to: bundleURL.appendingPathComponent("ManagedRuntime.json"))
        default:
            break
        }
        #expect(throws: Error.self) {
            _ = try ManagedRuntimeSpecification.bundled(bundleURL: appURL, resourceURL: resourceURL)
        }
    }

    @Test func givenNonAppExecution_whenLoaded_thenItRetainsSwiftPMResourceBehavior() throws {
        let fixtureRoot = try makeTempDir("managed-runtime-package")
        let specification = try ManagedRuntimeSpecification.bundled(bundleURL: fixtureRoot, resourceURL: nil)
        #expect(specification.engineVersion == "0.0.1")
    }

    @Test(arguments: [
        ("wrong host", "https://example.com/dependency-1.0.0-py3-none-any.whl"),
        ("wrong filename", "https://files.pythonhosted.org/packages/other.whl"),
        ("non-HTTPS", "http://files.pythonhosted.org/packages/dependency.whl")
    ])
    func givenForeignWheelMetadata_whenValidated_thenItIsRejected(_: String, url: String) {
        // given
        let wheel = artifact(url: url)

        // when / then
        #expect(throws: ManagedRuntimeFailure.self) {
            try wheel.validate(wheel: true)
        }
    }

    @Test(arguments: [
        String(repeating: "A", count: 64),
        String(repeating: "a", count: 63),
        "not-a-sha256"
    ])
    func givenInvalidHashMetadata_whenValidated_thenItIsRejected(_ hash: String) {
        // given
        let wheel = artifact(hash: hash)

        // when / then
        #expect(throws: ManagedRuntimeFailure.self) {
            try wheel.validate(wheel: true)
        }
    }

    @Test func givenLayoutHomeWithSpaces_whenConstructed_thenAllManagedPathsStayUnderThatHome() {
        // given / when
        let layout = ManagedRuntimeLayout(home: "/tmp/Harflow Fixture")

        // then
        #expect(layout.home == "/tmp/Harflow Fixture")
        #expect(layout.stateRoot == "/tmp/Harflow Fixture/.harflow")
        #expect(layout.runtimeRoot == "/tmp/Harflow Fixture/Library/Application Support/Harflow/Runtime")
        #expect(layout.tasksDirectory.hasPrefix(layout.home + "/"))
        #expect(layout.binDirectory.hasPrefix(layout.home + "/"))
    }
}
