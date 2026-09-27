//
//  HarnessesViewModelMock.swift
//  SettingsFeature
//

#if DEBUG

import Foundation
import MonitorCore
import PbUI

// MARK: - HarnessesViewModelMock

/// Preview mock for `HarnessesView`.
@MainActor
final class HarnessesViewModelMock: HarnessesViewModel {
    
    var rows: [HarnessRow]
    var serverPath: String?
    var errorMessage: String?
    var isLoading: Bool
    var workingKey: String?
    var isRefreshDisabled: Bool { isLoading || workingKey != nil }
    var installBannerModel: InstallBanner.Model?

    init(
        rows: [HarnessRow] = HarnessesViewModelMock.sampleRows,
        serverPath: String? = "/usr/local/bin/polybridge",
        errorMessage: String? = nil,
        isLoading: Bool = false,
        workingKey: String? = nil,
        installBannerModel: InstallBanner.Model? = nil
    ) {
        self.rows = rows
        self.serverPath = serverPath
        self.errorMessage = errorMessage
        self.isLoading = isLoading
        self.workingKey = workingKey
        self.installBannerModel = installBannerModel
    }

    func didAppear() {}
    func didDisappear() {}
    func didTapRefresh() {}
    func didTapInstall(_: HarnessRow) {}
    func didTapRemove(_: HarnessRow) {}
    func didTapInstallBannerPrimary() {}
    func didTapInstallBannerSecondary() {}
    func didTapInstallBannerDismiss() {}
    
    /// `HarnessRow` has no public initializer — built through the same public
    /// `SetupDocument.decode` entry point the app uses.
    static var sampleRows: [HarnessRow] {
        let json = #"""
        {"v":1,"server_path":"/usr/local/bin/polybridge","clients":[
            {"key":"claude-code","available":true,"installed":true,"current":true},
            {"key":"codex","available":true,"installed":false}
        ]}
        """#
        return (try? SetupDocument.decode(stdout: Data(json.utf8), stderr: "", exitCode: 0).get())?.rows ?? []
    }
}

#endif
