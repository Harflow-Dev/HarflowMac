// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PbCommon",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PbCommon", targets: ["PbCommon"]),
        .library(name: "PbCommonTestMock", targets: ["PbCommonTestMock"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../PbUtilities"),

        // MARK: Remote Dependencies

        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/hainayanda/Dummyable.git", exact: "1.1.6"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "PbCommon",
            dependencies: [
                "PbUtilities", "SwiftEnvironment", "Dummyable", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .target(
            name: "PbCommonTestMock",
            dependencies: [
                "PbCommon", "Mockable"
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug))
            ]
        ),
        .testTarget(
            name: "PbCommonTests",
            dependencies: [
                "PbCommon", "PbCommonTestMock", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
)
