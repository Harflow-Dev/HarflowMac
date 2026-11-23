//
//  HarnessesViewModelMock.swift
//  SettingsFeature
//

#if DEBUG

import Foundation
import HfUI
import MonitorCore

// MARK: - HarnessesViewModelMock

/// Preview mock for `HarnessesView`.
@MainActor
final class HarnessesViewModelMock: HarnessesViewModel {
    var qualificationCards: [QualificationCard] = [.init(id: "fixture", model: .init(
        identity: "Fixture harness · fixture version", state: .ready, message: "Fixture required features are ready.",
        features: [.init(id: "fixture_feature", result: "Ready · seeded")]))]

    var qualificationNotes: [QualificationNote] = [
        .make(for: QualificationBackend(backend: "opencode", installed: true)),
        .make(for: QualificationBackend(backend: "antigravity", installed: false))
    ]

    var rows: [HarnessRow]
    var serverPath: String?
    var loadFailure: HarnessLoadFailure?
    var rowFailures: [String: HarnessRowFailure]
    var isLoading: Bool
    var workingKey: String?
    var showsRuntimeSetup: Bool
    var showsNoHarnesses: Bool
    var isRefreshDisabled: Bool { showsRuntimeSetup || isLoading || workingKey != nil }

    init(
        rows: [HarnessRow] = HarnessesViewModelMock.sampleRows,
        serverPath: String? = "/usr/local/bin/harflow",
        loadFailure: HarnessLoadFailure? = nil,
        rowFailures: [String: HarnessRowFailure] = [:],
        isLoading: Bool = false,
        workingKey: String? = nil,
        showsRuntimeSetup: Bool = false,
        showsNoHarnesses: Bool = false
    ) {
        self.rows = rows
        self.serverPath = serverPath
        self.loadFailure = loadFailure
        self.rowFailures = rowFailures
        self.isLoading = isLoading
        self.workingKey = workingKey
        self.showsRuntimeSetup = showsRuntimeSetup
        self.showsNoHarnesses = showsNoHarnesses
    }

    func didAppear() {}
    func didDisappear() {}
    func didTapRefresh() {}
    func didTapInstall(_: HarnessRow) {}
    func didTapRemove(_: HarnessRow) {}
    func didTapRetry(_: HarnessRow) {}
    func didTapOpenSetup() {}

    /// A failed update of the second sample row, as the registration-failed state draws it.
    static var sampleRowFailures: [String: HarnessRowFailure] {
        ["codex": HarnessRowFailure(message: "Could not update the Codex configuration: permission denied", code: "setup_error", action: .install)]
    }
    
    /// `HarnessRow` has no public initializer — built through the same public
    /// `SetupDocument.decode` entry point the app uses.
    static var sampleRows: [HarnessRow] {
        let json = #"""
        {"product":"harflow","format":"\#(WireContract.setup.format)","v":1,"product_version":"\#(HarflowVersion.current)",
         "server_path":"/usr/local/bin/harflow","clients":[
            {"key":"claude-code","available":true,"installed":true,"current":true},
            {"key":"codex","available":true,"installed":false}
        ]}
        """#
        return (try? SetupDocument.decode(stdout: Data(json.utf8), stderr: "", exitCode: 0).get())?.rows ?? []
    }
}

#endif
