// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MonitorCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MonitorCore", targets: ["MonitorCore"])
    ],
    targets: [
        // Everything testable: decoding, tailing, lineage, git parsing, process/env building.
        // Foundation only, so the unit tests never need a window server.
        .target(
            name: "MonitorCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MonitorCoreTests",
            dependencies: ["MonitorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ],
    swiftLanguageModes: [.v5]
)
