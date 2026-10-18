// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MainWindowFeature",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MainWindowFeature", targets: ["MainWindowFeature"])
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
            name: "MainWindowFeature",
            dependencies: [
                "HfUtilities", "HfCommon", "HfUI", "MonitorCore", "HfRepository", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "MainWindowFeatureTests",
            dependencies: [
                "MainWindowFeature", "HfUtilities", "HfCommon", "HfUI", "MonitorCore", "HfRepository", "SwiftEnvironment", "Mockable",
                .product(name: "HfTestUtilities", package: "HfUtilities"),
                .product(name: "HfCommonTestMock", package: "HfCommon")
            ],
            resources: [.copy("Workflow/Fixtures")],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
