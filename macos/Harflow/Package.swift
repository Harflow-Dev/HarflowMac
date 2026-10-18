// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Harflow",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Harflow", targets: ["Harflow"])
    ],
    dependencies: [
        // MARK: Local Dependencies

        .package(path: "../HfCore/MonitorCore"),
        .package(path: "../HfCore/HfRepository"),
        .package(path: "../HfFoundation/HfUtilities"),
        .package(path: "../HfFoundation/HfCommon"),
        .package(path: "../HfFeatures/SettingsFeature"),
        .package(path: "../HfFeatures/MenuBarFeature"),
        .package(path: "../HfFeatures/MainWindowFeature"),

        // MARK: Remote Dependencies

        // `AppCoordinator`/`App.swift` read `GlobalValues` directly — every target declares every
        // product it imports, so this is declared here too, not only transitively through
        // HfRepository.
        .package(url: "https://github.com/hainayanda/SwiftEnvironment.git", exact: "4.1.8"),
        .package(url: "https://github.com/Kolos65/Mockable.git", exact: "0.6.2")
    ],
    targets: [
        .executableTarget(
            name: "Harflow",
            dependencies: [
                "MonitorCore", "HfRepository", "HfUtilities", "HfCommon", "SwiftEnvironment",
                "SettingsFeature", "MenuBarFeature", "MainWindowFeature"
            ]
        ),
        // Phase 5: the app shell's own tests — `AppModulesRegistry`, `AppCoordinator`, `AppDelegate`.
        // SwiftPM can `@testable import` an executable target from a test target in the same package.
        .testTarget(
            name: "HarflowTests",
            dependencies: [
                "Harflow", "MonitorCore", "HfRepository", "HfUtilities", "HfCommon",
                "SettingsFeature", "MenuBarFeature", "MainWindowFeature", "SwiftEnvironment", "Mockable",
                .product(name: "HfTestUtilities", package: "HfUtilities"),
                .product(name: "HfCommonTestMock", package: "HfCommon")
            ],
            swiftSettings: [
                .define("MOCKING")
            ]
        )
    ]
    // Phase 5: the app shell no longer holds `TerminalSession`/`TerminalHost` (moved to the
    // `HfTerminal` package in Phase 3B, itself deleted once the Monitor's take-over flow moved to
    // Terminal.app only) — that was the only thing in this target that failed to compile in Swift 6
    // mode (a `#SendingRisksDataRace` error on its `assumeIsolated` hop around the SwiftTerm delegate
    // callback — decision 2's issue). With that code gone, this package builds and tests cleanly in
    // Swift 6 mode (the tools-version default), so no `swiftLanguageModes` override is declared here
    // any more.
)
