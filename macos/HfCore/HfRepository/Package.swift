// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HfRepository",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HfRepository", targets: ["HfRepository"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../MonitorCore"),
        .package(path: "../../HfFoundation/HfUtilities"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "HfRepository",
            dependencies: [
                "MonitorCore", "HfUtilities", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "HfRepositoryTests",
            dependencies: [
                "HfRepository", "MonitorCore", "HfUtilities", "SwiftEnvironment", "Mockable",
                .product(name: "HfTestUtilities", package: "HfUtilities")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
