// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PbTerminal",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PbTerminal", targets: ["PbTerminal"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../PbRepository"),
        .package(path: "../MonitorCore"),
        .package(path: "../../PbFoundation/PbUtilities"),

        // MARK: Remote Dependencies

        // The only module allowed to depend on SwiftTerm — see this package's AGENTS.md.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", exact: "1.20.0"),
        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .target(
            name: "PbTerminal",
            dependencies: [
                "PbRepository", "MonitorCore", "PbUtilities", "SwiftEnvironment", "Mockable",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            swiftSettings: [
                .define("MOCKING", .when(configuration: .debug)),
                .swiftLanguageMode(.v5)
            ]
        ),
        .testTarget(
            name: "PbTerminalTests",
            dependencies: [
                "PbTerminal", "PbRepository", "MonitorCore", "PbUtilities", "SwiftEnvironment", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities")
            ],
            swiftSettings: [
                .define("MOCKING"),
                .swiftLanguageMode(.v5)
            ]
        )
    ],
    // Decision 2: MonitorCore and PbTerminal use Swift 5 mode. SwiftTerm's delegate hops (the
    // `assumeIsolated` calls kept from today's TerminalSession) do not compile under Swift 6's
    // strict concurrency checking — see AGENTS.md.
    swiftLanguageModes: [.v5]
)
