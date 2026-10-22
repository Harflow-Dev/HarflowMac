import Darwin
import Foundation
import MonitorCore
import SwiftUI

// MARK: - HarflowEntryPoint

@main
@MainActor
enum HarflowEntryPoint {
    static func main() {
        if let status = run(arguments: Array(CommandLine.arguments.dropFirst()), diagnostic: {
            let result = PackagedStartup.check()
            FileHandle.standardOutput.write(result.output)
            return result.status
        }, launch: { HarflowApp.main() }) {
            exit(status)
        }
    }

    static func run(arguments: [String], diagnostic: () -> Int32, launch: () -> Void) -> Int32? {
        if arguments == ["--check-packaged-startup"] {
            return diagnostic()
        }
        launch()
        return nil
    }
}

// MARK: - PackagedStartup

enum PackagedStartup {
    static func check(
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        appVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        loadSpecification: () throws -> ManagedRuntimeSpecification = { try .bundled() }
    ) -> (status: Int32, output: Data) {
        do {
            guard bundleURL.pathExtension == "app", bundleIdentifier == "dev.harflow.mac",
                  let appVersion,
                  appVersion.range(of: #"\A(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\z"#,
                                   options: .regularExpression) != nil else {
                throw ManagedRuntimeFailure("Invalid packaged app identity.")
            }
            let specification = try loadSpecification()
            try specification.validate()
            let output = try JSONSerialization.data(withJSONObject: [
                "appVersion": appVersion, "engineVersion": specification.engineVersion, "status": "ok"
            ], options: [.sortedKeys])
            guard output.count <= 4095 else {
                throw ManagedRuntimeFailure("Packaged startup result exceeds its output limit.")
            }
            return (0, output + Data([0x0A]))
        } catch {
            return (1, Data("{\"status\":\"failed\"}\n".utf8))
        }
    }
}
