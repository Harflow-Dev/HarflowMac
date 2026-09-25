// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "PolybridgeMonitor",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "PolybridgeMonitor", targets: ["PolybridgeMonitor"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../PbCore/MonitorCore"),
        .package(path: "../PbCore/PbRepository"),
        .package(path: "../PbCore/PbTerminal"),
        .package(path: "../PbFoundation/PbUtilities"),
        .package(path: "../PbFoundation/PbCommon"),
        .package(path: "../PbFeatures/SettingsFeature"),
        .package(path: "../PbFeatures/MenuBarFeature"),
        .package(path: "../PbFeatures/MainWindowFeature"),

        // MARK: Remote Dependencies

        // `AppCoordinator`/`App.swift` read `GlobalValues` directly — every target declares every
        // product it imports, so this is declared here too, not only transitively through
        // PbRepository/PbTerminal.
        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .executableTarget(
            name: "PolybridgeMonitor",
            dependencies: [
                "MonitorCore", "PbRepository", "PbTerminal", "PbUtilities", "PbCommon", "SwiftEnvironment",
                "SettingsFeature", "MenuBarFeature", "MainWindowFeature"
            ]
        ),
        // Phase 5: the app shell's own tests — `AppModulesRegistry`, `AppCoordinator`, `AppDelegate`.
        // SwiftPM can `@testable import` an executable target from a test target in the same package.
        .testTarget(
            name: "PolybridgeMonitorTests",
            dependencies: [
                "PolybridgeMonitor", "MonitorCore", "PbRepository", "PbTerminal", "PbUtilities", "PbCommon",
                "SettingsFeature", "MenuBarFeature", "MainWindowFeature", "SwiftEnvironment", "Mockable",
                .product(name: "PbTestUtilities", package: "PbUtilities"),
                .product(name: "PbCommonTestMock", package: "PbCommon")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
    // Phase 5: the app shell no longer holds `TerminalSession`/`TerminalHost` (moved to `PbTerminal`
    // in Phase 3B, which stays `.v5` on its own) — that was the only thing in this target that failed
    // to compile in Swift 6 mode (a `#SendingRisksDataRace` error on its `assumeIsolated` hop around
    // the SwiftTerm delegate callback — decision 2's issue). With that code gone, this package builds
    // and tests cleanly in Swift 6 mode (the tools-version default), so no `swiftLanguageModes`
    // override is declared here any more.
)
