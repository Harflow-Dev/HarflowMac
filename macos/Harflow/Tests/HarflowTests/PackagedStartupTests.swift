import Foundation
@testable import Harflow
import MonitorCore
import Testing

@Suite("Packaged startup diagnostic")
struct PackagedStartupTests {
    private let appURL = URL(fileURLWithPath: "/tmp/Harflow Fixture/Harflow.app")

    private func fixtureArtifact() -> ManagedRuntimeArtifact {
        ManagedRuntimeArtifact(
            name: "python", version: "3.13.16", filename: "python.tar.gz",
            url: URL(string: "https://example.com/python.tar.gz")!,
            sha256: String(repeating: "a", count: 64), size: 1
        )
    }

    @Test func givenValidPackagedIdentityAndSpecification_whenChecked_thenItEmitsSuccessIdentity() throws {
        let specification = try ManagedRuntimeSpecification.bundled()
        let result = PackagedStartup.check(
            bundleURL: appURL,
            bundleIdentifier: "dev.harflow.mac",
            appVersion: "0.0.2",
            loadSpecification: { specification }
        )

        #expect(result.status == 0)
        let object = try #require(JSONSerialization.jsonObject(with: result.output) as? [String: String])
        #expect(object["status"] == "ok")
        #expect(object["appVersion"] == "0.0.2")
        #expect(object["engineVersion"] == "0.0.1")
    }

    @Test func givenInvalidPackagedIdentity_whenChecked_thenItFailsBeforeLoadingSpecification() {
        var loaded = false
        let result = PackagedStartup.check(
            bundleURL: URL(fileURLWithPath: "/tmp/Harflow Fixture/not-an-app"),
            bundleIdentifier: "dev.harflow.mac",
            appVersion: "0.0.2",
            loadSpecification: {
                loaded = true
                return try ManagedRuntimeSpecification.bundled()
            }
        )

        #expect(result.status != 0)
        #expect(!loaded)
        #expect((try? JSONSerialization.jsonObject(with: result.output) as? [String: String])?["status"] == "failed")
    }

    @Test func givenInvalidSpecification_whenChecked_thenItEmitsBoundedFailure() {
        let result = PackagedStartup.check(
            bundleURL: appURL,
            bundleIdentifier: "dev.harflow.mac",
            appVersion: "0.0.2",
            loadSpecification: { throw ManagedRuntimeFailure("fixture failure") }
        )

        #expect(result.status != 0)
        #expect(result.output.count < 256)
        #expect((try? JSONSerialization.jsonObject(with: result.output) as? [String: String])?["status"] == "failed")
    }

    @Test func givenDecodedButInvalidSpecification_whenChecked_thenItFailsValidation() {
        let invalid = ManagedRuntimeSpecification(
            schema: 99, engineVersion: "0.0.1", pythonVersion: "3.13.16",
            python: fixtureArtifact(), dependencies: [fixtureArtifact()], provenance: "fixture"
        )
        let result = PackagedStartup.check(
            bundleURL: appURL, bundleIdentifier: "dev.harflow.mac", appVersion: "0.0.2",
            loadSpecification: { invalid }
        )
        #expect(result.status != 0)
        #expect(result.output == Data("{\"status\":\"failed\"}\n".utf8))
    }

    @Test(arguments: ["0.0.02", "0.0.2\n", "1.2"])
    func givenNonCanonicalAppVersion_whenChecked_thenItFailsBeforeLoading(_ version: String) {
        var loaded = false
        let result = PackagedStartup.check(
            bundleURL: appURL, bundleIdentifier: "dev.harflow.mac", appVersion: version,
            loadSpecification: {
                loaded = true
                return try ManagedRuntimeSpecification.bundled()
            }
        )
        #expect(result.status != 0)
        #expect(!loaded)
    }

    @Test func givenOversizedValidAppVersion_whenChecked_thenItEmitsBoundedFailure() {
        let version = "1." + String(repeating: "9", count: 4090) + ".0"
        var loaded = false
        let result = PackagedStartup.check(
            bundleURL: appURL, bundleIdentifier: "dev.harflow.mac", appVersion: version,
            loadSpecification: {
                loaded = true
                return try ManagedRuntimeSpecification.bundled()
            }
        )
        #expect(result.status != 0)
        #expect(result.output.count < 256)
        #expect(loaded)
    }

    @Test @MainActor func givenDiagnosticArgument_whenRun_thenItDoesNotLaunchTheApp() {
        var launched = false
        var diagnosed = false
        let status = HarflowEntryPoint.run(
            arguments: ["--check-packaged-startup"],
            diagnostic: {
                diagnosed = true
                return 0
            },
            launch: { launched = true }
        )

        #expect(status == 0)
        #expect(diagnosed)
        #expect(!launched)
    }

    @Test @MainActor func givenNormalArguments_whenRun_thenItDelegatesToTheApp() {
        var launched = false
        var diagnosed = false
        let status = HarflowEntryPoint.run(
            arguments: [],
            diagnostic: {
                diagnosed = true
                return 0
            },
            launch: { launched = true }
        )

        #expect(status == nil)
        #expect(launched)
        #expect(!diagnosed)
    }

    @Test @MainActor func givenDiagnosticFlagWithExtraArguments_whenRun_thenItDelegatesToTheApp() {
        var launched = false
        var diagnosed = false
        let status = HarflowEntryPoint.run(
            arguments: ["--check-packaged-startup", "extra"],
            diagnostic: {
                diagnosed = true
                return 0
            },
            launch: { launched = true }
        )
        #expect(status == nil)
        #expect(launched)
        #expect(!diagnosed)
    }
}
