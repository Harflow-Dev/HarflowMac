// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MainWindowFeature",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MainWindowFeature", targets: ["MainWindowFeature"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../../PbFoundation/PbUtilities"),
        .package(path: "../../PbFoundation/PbCommon"),
        .package(path: "../../PbFoundation/PbUI"),
        .package(path: "../../PbCore/MonitorCore"),
        .package(path: "../../PbCore/PbRepository"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "MainWindowFeature",
            dependencies: [
                "PbUtilities", "PbCommon", "PbUI", "MonitorCore", "PbRepository", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "MainWindowFeatureTests",
            dependencies: [
                "MainWindowFeature", "PbUtilities", "PbCommon", "PbUI", "MonitorCore", "PbRepository", "SwiftEnvironment", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities"),
                .product(name: "PbCommonTestMock", package: "PbCommon")
            ],
            resources: [.copy("Workflow/Fixtures")],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
