// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PbUtilities",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PbUtilities", targets: ["PbUtilities"]),
        .library(name: "PbTestUtilities", targets: ["PbTestUtilities"])
    ],
    dependencies: [
        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/hainayanda/Dummyable.git", exact: "1.1.6"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "PbUtilities",
            dependencies: [
                "Dummyable", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "PbTestUtilities",
            dependencies: [
                "Dummyable"
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        ),
        .testTarget(
            name: "PbUtilitiesTests",
            dependencies: [
                "PbUtilities", "PbTestUtilities", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
