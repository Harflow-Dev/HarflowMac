// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SettingsFeature",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SettingsFeature", targets: ["SettingsFeature"])
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
            name: "SettingsFeature",
            dependencies: [
                "PbUtilities", "PbCommon", "PbUI", "MonitorCore", "PbRepository", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "SettingsFeatureTests",
            dependencies: [
                "SettingsFeature", "PbUtilities", "PbCommon", "PbUI", "MonitorCore", "PbRepository", "SwiftEnvironment", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities"),
                .product(name: "PbCommonTestMock", package: "PbCommon")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
