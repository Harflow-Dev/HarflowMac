// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PolybridgeMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PolybridgeMonitor", targets: ["PolybridgeMonitor"]),
    ],
    dependencies: [
        // Pinned to a released tag; the only dependency the app takes.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        // Everything testable: decoding, tailing, lineage, git parsing, process/env building.
        // Foundation only, so the unit tests never need a window server.
        .target(name: "MonitorCore"),
        .executableTarget(
            name: "PolybridgeMonitor",
            dependencies: ["MonitorCore", .product(name: "SwiftTerm", package: "SwiftTerm")]
        ),
        .testTarget(name: "MonitorCoreTests", dependencies: ["MonitorCore"]),
    ]
)
