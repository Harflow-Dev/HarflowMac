// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HfUtilities",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HfUtilities", targets: ["HfUtilities"]),
        .library(name: "HfTestUtilities", targets: ["HfTestUtilities"])
    ],
    dependencies: [
        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/hainayanda/Dummyable.git", exact: "1.1.6"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "HfUtilities",
            dependencies: [
                "Dummyable", "SwiftEnvironment", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "HfTestUtilities",
            dependencies: [
                "Dummyable"
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        ),
        .testTarget(
            name: "HfUtilitiesTests",
            dependencies: [
                "HfUtilities", "HfTestUtilities", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
