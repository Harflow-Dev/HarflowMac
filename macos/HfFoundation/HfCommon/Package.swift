// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HfCommon",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "HfCommon", targets: ["HfCommon"]),
        .library(name: "HfCommonTestMock", targets: ["HfCommonTestMock"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../HfUtilities"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/hainayanda/Dummyable.git", exact: "1.1.6"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "HfCommon",
            dependencies: [
                "HfUtilities", "SwiftEnvironment", "Dummyable", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "HfCommonTestMock",
            dependencies: [
                "HfCommon", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "HfCommonTests",
            dependencies: [
                "HfCommon", "HfCommonTestMock", "Mockable",
                .product(name: "HfTestUtilities", package: "HfUtilities")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
