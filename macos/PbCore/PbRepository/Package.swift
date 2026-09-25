// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PbRepository",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PbRepository", targets: ["PbRepository"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../MonitorCore"),
        .package(path: "../../PbFoundation/PbUtilities"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "PbRepository",
            dependencies: [
                "MonitorCore", "PbUtilities", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "PbRepositoryTests",
            dependencies: [
                "PbRepository", "MonitorCore", "PbUtilities", "SwiftEnvironment", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
