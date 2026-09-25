// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PolybridgeMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PolybridgeMonitor", targets: ["PolybridgeMonitor"]),
    ],
    dependencies: [
        // Decoding, tailing, lineage, git parsing and process/env building live in their own
        // package, with their own tests.
        .package(path: "../PbCore/MonitorCore"),
        // Pinned to a released tag.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
    ],
    targets: [
        .executableTarget(
            name: "PolybridgeMonitor",
            dependencies: [
                .product(name: "MonitorCore", package: "MonitorCore"),
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
    ]
)
