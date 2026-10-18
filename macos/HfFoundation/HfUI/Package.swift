// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HfUI",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HfUI", targets: ["HfUI"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../HfUtilities"),
        .package(path: "../HfCommon"),
        .package(path: "../../HfCore/MonitorCore")
    ],
    targets: [
        .target(
            name: "HfUI",
            dependencies: [
                "HfUtilities", "HfCommon", "MonitorCore"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "HfUITests",
            dependencies: [
                "HfUI", "HfCommon",
                .product(name: "HfTestUtilities", package: "HfUtilities")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
