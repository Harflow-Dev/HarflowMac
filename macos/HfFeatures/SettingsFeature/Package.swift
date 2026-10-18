// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SettingsFeature",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SettingsFeature", targets: ["SettingsFeature"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../../HfFoundation/HfUtilities"),
        .package(path: "../../HfFoundation/HfCommon"),
        .package(path: "../../HfFoundation/HfUI"),
        .package(path: "../../HfCore/MonitorCore"),
        .package(path: "../../HfCore/HfRepository"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "SettingsFeature",
            dependencies: [
                "HfUtilities", "HfCommon", "HfUI", "MonitorCore", "HfRepository", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "SettingsFeatureTests",
            dependencies: [
                "SettingsFeature", "HfUtilities", "HfCommon", "HfUI", "MonitorCore", "HfRepository", "SwiftEnvironment", "Mockable",
                .product(name: "HfTestUtilities", package: "HfUtilities"),
                .product(name: "HfCommonTestMock", package: "HfCommon")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
