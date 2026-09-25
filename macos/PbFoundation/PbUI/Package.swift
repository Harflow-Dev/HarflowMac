// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PbUI",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PbUI", targets: ["PbUI"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../PbUtilities"),
        .package(path: "../PbCommon"),
        .package(path: "../../PbCore/MonitorCore")
    ],
    targets: [
        .target(
            name: "PbUI",
            dependencies: [
                "PbUtilities", "PbCommon", "MonitorCore"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "PbUITests",
            dependencies: [
                "PbUI"
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
