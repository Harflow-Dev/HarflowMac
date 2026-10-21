import Foundation
@testable import MonitorCore
import Testing

@Suite("Managed runtime specification")
struct ManagedRuntimeSpecificationTests {
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
